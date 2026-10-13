// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlDefaultAdminRulesUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "../interfaces/IStakedTrUSDCooldown.sol";
import "./TrUsdSilo.sol";

/// @notice Interface for ERC20 tokens with burn capability
interface IERC20Burnable {
    function burn(uint256 amount) external;
}

/**
 * @title StakedTrUSD
 * @notice ERC4626 vault for staking TrUSD with optional cooldown mechanism
 */
contract StakedTrUSD is
    Initializable,
    IStakedTrUSDCooldown,
    AccessControlDefaultAdminRulesUpgradeable,
    ReentrancyGuardUpgradeable,
    ERC20PermitUpgradeable,
    ERC4626Upgradeable,
    UUPSUpgradeable
{
    using SafeERC20 for IERC20;

    /* ------------- CONSTANTS ------------- */
    bytes32 private constant REWARDER_ROLE = keccak256("REWARDER_ROLE");
    bytes32 private constant BLACKLIST_MANAGER_ROLE = keccak256("BLACKLIST_MANAGER_ROLE");
    bytes32 private constant FULL_RESTRICTED_STAKER_ROLE = keccak256("FULL_RESTRICTED_STAKER_ROLE");
    /// @notice Role for timelock-protected operations (upgradeTo)
    bytes32 public constant TIMELOCK_ADMIN_ROLE = keccak256("TIMELOCK_ADMIN_ROLE");
    uint256 private constant VESTING_PERIOD = 8 hours;
    uint256 private constant MIN_SHARES = 1 ether;
    /// @notice Ceiling on one `reportLoss`, in basis points of totalAssets(). Reports are at least LOSS_INTERVAL
    ///         apart, so no 24-hour span loses more. Changing either takes a timelocked upgrade.
    uint256 public constant MAX_DAILY_LOSS_BPS = 500;
    uint256 public constant LOSS_INTERVAL = 1 days;
    uint256 private constant BPS_DENOMINATOR = 10_000;

    /* ------------- STORAGE ------------- */
    struct StakedTrUSDStorage {
        uint256 vestingAmount;
        uint256 lastDistributionTimestamp;
        mapping(address => UserCooldown) cooldowns;
        TrUsdSilo silo;
        uint24 maxCooldownDuration;
        uint24 cooldownDuration;
        bool timelockAdminInitialized;
        /// @dev block.timestamp of the last accepted reportLoss; the next one waits LOSS_INTERVAL.
        uint256 lastLossTimestamp;
    }

    bytes32 private constant STAKED_TR_USD_STORAGE_LOCATION =
        0x3c4d5e6f7a8b9c0d1e2f3a4b5c6d7e8f9a0b1c2d3e4f5a6b7c8d9e0f1a2b3c00;

    function _getStakedTrUSDStorage() private pure returns (StakedTrUSDStorage storage $) {
        assembly {
            $.slot := STAKED_TR_USD_STORAGE_LOCATION
        }
    }

    /* ------------- MODIFIERS ------------- */
    modifier notZero(uint256 amount) {
        if (amount == 0) revert InvalidAmount();
        _;
    }

    modifier notOwner(address target) {
        if (target == owner()) revert CantBlacklistOwner();
        _;
    }

    modifier ensureCooldownOff() {
        StakedTrUSDStorage storage $ = _getStakedTrUSDStorage();
        if ($.cooldownDuration != 0) revert OperationNotAllowed();
        _;
    }

    modifier ensureCooldownOn() {
        StakedTrUSDStorage storage $ = _getStakedTrUSDStorage();
        if ($.cooldownDuration == 0) revert OperationNotAllowed();
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /* ------------- INITIALIZER ------------- */
    function initialize(address _asset, address _initialRewarder, address _owner) public initializer {
        if (_owner == address(0) || _initialRewarder == address(0) || _asset == address(0)) {
            revert InvalidZeroAddress();
        }

        __AccessControlDefaultAdminRules_init(1 days, _owner);
        __ReentrancyGuard_init();
        __ERC20_init("Staked trUSD", "strUSD");
        __ERC20Permit_init("strUSD");
        __ERC4626_init(IERC20(_asset));
        __UUPSUpgradeable_init();
        _grantRole(REWARDER_ROLE, _initialRewarder);
        _grantRole(BLACKLIST_MANAGER_ROLE, _owner);

        StakedTrUSDStorage storage $ = _getStakedTrUSDStorage();
        $.maxCooldownDuration = 90 days;
        $.cooldownDuration = 7 days;
        $.silo = new TrUsdSilo(address(this), _asset);
    }

    /* ------------- EXTERNAL ------------- */
    function transferInRewards(uint256 amount) external nonReentrant onlyRole(REWARDER_ROLE) notZero(amount) {
        _updateVestingAmount(amount);
        IERC20(asset()).safeTransferFrom(msg.sender, address(this), amount);

        emit RewardsReceived(amount);
    }

    /// @notice Writes down `amount` of assets: unvested rewards absorb it first, the rest is burned.
    /// @dev At most one report per LOSS_INTERVAL (LossReportTooSoon) and at most MAX_DAILY_LOSS_BPS of
    ///      totalAssets() per report (DailyLossCapExceeded); see `remainingDailyLoss`.
    function reportLoss(uint256 amount) external nonReentrant onlyRole(REWARDER_ROLE) notZero(amount) {
        StakedTrUSDStorage storage $ = _getStakedTrUSDStorage();
        _consumeDailyLossCap($, amount);
        uint256 unvested = getUnvestedAmount();
        uint256 unvestedCancelled = 0;

        if (unvested > 0) {
            if (amount >= unvested) {
                unvestedCancelled = unvested;
                $.vestingAmount = 0;
                $.lastDistributionTimestamp = block.timestamp;
            } else {
                uint256 timeSinceLastDistribution = block.timestamp - $.lastDistributionTimestamp;
                uint256 timeRemaining = VESTING_PERIOD - timeSinceLastDistribution;

                // Calculate target unvested after loss
                uint256 newUnvested = unvested - amount;

                // Solve for newVestingAmount
                uint256 newVestingAmount = (newUnvested * VESTING_PERIOD) / timeRemaining;

                $.vestingAmount = newVestingAmount;
                unvestedCancelled = amount;
            }
        }

        uint256 totalBurn = amount;

        uint256 available = IERC20(asset()).balanceOf(address(this));

        if (available >= totalBurn) {
            IERC20Burnable(asset()).burn(totalBurn);
            emit LossReported(amount);
        } else {
            IERC20Burnable(asset()).burn(available);
            emit LossReported(available);
        }
    }

    function addToBlacklist(address target) external onlyRole(BLACKLIST_MANAGER_ROLE) notOwner(target) {
        _grantRole(FULL_RESTRICTED_STAKER_ROLE, target);
    }

    function removeFromBlacklist(address target) external onlyRole(BLACKLIST_MANAGER_ROLE) notOwner(target) {
        _revokeRole(FULL_RESTRICTED_STAKER_ROLE, target);
    }

    function addToBlacklistBatch(address[] calldata targets) external onlyRole(BLACKLIST_MANAGER_ROLE) {
        if (targets.length == 0) revert InvalidAmount();

        address _owner = owner();
        for (uint256 i = 0; i < targets.length;) {
            if (targets[i] == _owner) revert CantBlacklistOwner();
            _grantRole(FULL_RESTRICTED_STAKER_ROLE, targets[i]);
            unchecked {
                ++i;
            }
        }
    }

    function removeFromBlacklistBatch(address[] calldata targets) external onlyRole(BLACKLIST_MANAGER_ROLE) {
        if (targets.length == 0) revert InvalidAmount();

        address _owner = owner();
        for (uint256 i = 0; i < targets.length;) {
            if (targets[i] == _owner) revert CantBlacklistOwner();
            _revokeRole(FULL_RESTRICTED_STAKER_ROLE, targets[i]);
            unchecked {
                ++i;
            }
        }
    }

    function rescueTokens(address token, uint256 amount, address to) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (address(token) == asset()) revert InvalidToken();
        IERC20(token).safeTransfer(to, amount);
    }

    function rescueSiloTokens(IERC20 token, address to, uint256 amount) external onlyRole(DEFAULT_ADMIN_ROLE) {
        StakedTrUSDStorage storage $ = _getStakedTrUSDStorage();
        $.silo.rescueToken(token, to, amount);
    }

    /**
     * @notice Rescue orphan funds when vault has assets but zero shares
     * @dev Can only be called when totalSupply() == 0 to ensure no stakers are affected
     * @param to Address to receive the orphan funds
     */
    function rescueOrphanFunds(address to) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (totalSupply() != 0) revert OperationNotAllowed();
        if (to == address(0)) revert InvalidZeroAddress();
        uint256 balance = IERC20(asset()).balanceOf(address(this));
        if (balance == 0) revert NoOrphanFunds();

        // Reset vesting state to prevent underflow in totalAssets()
        StakedTrUSDStorage storage $ = _getStakedTrUSDStorage();
        $.vestingAmount = 0;
        $.lastDistributionTimestamp = block.timestamp;

        IERC20(asset()).safeTransfer(to, balance);
        emit OrphanFundsRescued(to, balance);
    }

    function redistributeLockedAmount(address from, address to) external nonReentrant onlyRole(DEFAULT_ADMIN_ROLE) {
        if (hasRole(FULL_RESTRICTED_STAKER_ROLE, from) && !hasRole(FULL_RESTRICTED_STAKER_ROLE, to)) {
            uint256 amountToDistribute = balanceOf(from);

            _burn(from, amountToDistribute);

            if (to != address(0)) {
                _mint(to, amountToDistribute);
            }
            // When to == address(0): assets remain in vault, share value increases instantly for remaining stakers

            _checkMinShares();

            emit LockedAmountRedistributed(from, to, amountToDistribute);
        } else {
            revert OperationNotAllowed();
        }
    }

    function seizeCooldown(address from, address to) external nonReentrant onlyRole(DEFAULT_ADMIN_ROLE) {
        if (!hasRole(FULL_RESTRICTED_STAKER_ROLE, from)) revert OperationNotAllowed();
        if (to == address(0)) revert InvalidZeroAddress();

        StakedTrUSDStorage storage $ = _getStakedTrUSDStorage();
        UserCooldown storage userCooldown = $.cooldowns[from];
        uint256 assets = userCooldown.underlyingAmount;

        if (assets == 0) revert InvalidAmount();

        userCooldown.cooldownEnd = 0;
        userCooldown.underlyingAmount = 0;

        $.silo.withdraw(to, assets);

        emit CooldownSeized(from, to, assets);
    }

    function withdraw(
        uint256 assets,
        address receiver,
        address _owner
    )
        public
        virtual
        override
        ensureCooldownOff
        returns (uint256)
    {
        return super.withdraw(assets, receiver, _owner);
    }

    function redeem(
        uint256 shares,
        address receiver,
        address _owner
    )
        public
        virtual
        override
        ensureCooldownOff
        returns (uint256)
    {
        return super.redeem(shares, receiver, _owner);
    }

    function unstake(address receiver) external {
        if (hasRole(FULL_RESTRICTED_STAKER_ROLE, msg.sender)) revert OperationNotAllowed();

        StakedTrUSDStorage storage $ = _getStakedTrUSDStorage();
        UserCooldown storage userCooldown = $.cooldowns[msg.sender];
        uint256 assets = userCooldown.underlyingAmount;

        if (block.timestamp >= userCooldown.cooldownEnd || $.cooldownDuration == 0) {
            userCooldown.cooldownEnd = 0;
            userCooldown.underlyingAmount = 0;
            $.silo.withdraw(receiver, assets);
        } else {
            revert InvalidCooldown();
        }
    }

    function cancelCooldown() external nonReentrant {
        StakedTrUSDStorage storage $ = _getStakedTrUSDStorage();
        UserCooldown storage userCooldown = $.cooldowns[msg.sender];
        uint256 assets = userCooldown.underlyingAmount;

        if (assets == 0) revert InvalidCooldown();

        // Check blacklist restrictions
        if (hasRole(FULL_RESTRICTED_STAKER_ROLE, msg.sender)) {
            revert OperationNotAllowed();
        }

        // Clear cooldown state
        userCooldown.cooldownEnd = 0;
        userCooldown.underlyingAmount = 0;

        uint256 shares = previewDeposit(assets);
        if (shares == 0) revert InvalidAmount();

        // Transfer assets from Silo back to vault
        $.silo.withdraw(address(this), assets);

        // Mint shares
        _mint(msg.sender, shares);

        // Ensure MIN_SHARES invariant
        _checkMinShares();

        emit CooldownCancelled(msg.sender, assets, shares);
    }

    function cooldownAssets(uint256 assets) external ensureCooldownOn returns (uint256) {
        if (assets > maxWithdraw(msg.sender)) revert ExcessiveWithdrawAmount();

        uint256 shares = previewWithdraw(assets);

        StakedTrUSDStorage storage $ = _getStakedTrUSDStorage();
        $.cooldowns[msg.sender].cooldownEnd = uint104(block.timestamp) + $.cooldownDuration;
        $.cooldowns[msg.sender].underlyingAmount += assets;

        _withdraw(msg.sender, address($.silo), msg.sender, assets, shares);

        return shares;
    }

    function cooldownShares(uint256 shares) external ensureCooldownOn returns (uint256) {
        if (shares > maxRedeem(msg.sender)) revert ExcessiveRedeemAmount();

        uint256 assets = previewRedeem(shares);

        StakedTrUSDStorage storage $ = _getStakedTrUSDStorage();
        $.cooldowns[msg.sender].cooldownEnd = uint104(block.timestamp) + $.cooldownDuration;
        $.cooldowns[msg.sender].underlyingAmount += assets;

        _withdraw(msg.sender, address($.silo), msg.sender, assets, shares);

        return assets;
    }

    function setCooldownDuration(uint24 duration) external onlyRole(DEFAULT_ADMIN_ROLE) {
        StakedTrUSDStorage storage $ = _getStakedTrUSDStorage();
        if (duration > $.maxCooldownDuration) {
            revert InvalidCooldown();
        }

        uint24 previousDuration = $.cooldownDuration;
        $.cooldownDuration = duration;
        emit CooldownDurationUpdated(previousDuration, $.cooldownDuration);
    }

    /* ------------- PUBLIC ------------- */
    function totalAssets() public view override returns (uint256) {
        return IERC20(asset()).balanceOf(address(this)) - getUnvestedAmount();
    }

    function getUnvestedAmount() public view returns (uint256) {
        StakedTrUSDStorage storage $ = _getStakedTrUSDStorage();
        uint256 timeSinceLastDistribution = block.timestamp - $.lastDistributionTimestamp;

        if (timeSinceLastDistribution >= VESTING_PERIOD) {
            return 0;
        }

        uint256 deltaT;
        unchecked {
            deltaT = (VESTING_PERIOD - timeSinceLastDistribution);
        }

        return (deltaT * $.vestingAmount) / VESTING_PERIOD;
    }

    function decimals() public pure override(ERC4626Upgradeable, ERC20Upgradeable) returns (uint8) {
        return 18;
    }

    function silo() external view returns (address) {
        StakedTrUSDStorage storage $ = _getStakedTrUSDStorage();
        return address($.silo);
    }

    function cooldownDuration() external view returns (uint24) {
        StakedTrUSDStorage storage $ = _getStakedTrUSDStorage();
        return $.cooldownDuration;
    }

    function cooldowns(address user) external view returns (UserCooldown memory) {
        StakedTrUSDStorage storage $ = _getStakedTrUSDStorage();
        return $.cooldowns[user];
    }

    function vestingAmount() external view returns (uint256) {
        StakedTrUSDStorage storage $ = _getStakedTrUSDStorage();
        return $.vestingAmount;
    }

    function lastDistributionTimestamp() external view returns (uint256) {
        StakedTrUSDStorage storage $ = _getStakedTrUSDStorage();
        return $.lastDistributionTimestamp;
    }

    /// @notice Largest `reportLoss` amount accepted right now: MAX_DAILY_LOSS_BPS of totalAssets(), or 0 until
    ///         LOSS_INTERVAL has passed since the last report.
    /// @dev Reports are at least a day apart and each is at most 5% of the vault as it stands, so no holder
    ///      loses more than 5% of share price in any 24-hour span. Amounts count gross, including the part
    ///      absorbed by unvested rewards.
    function remainingDailyLoss() external view returns (uint256) {
        return _remainingDailyLoss(_getStakedTrUSDStorage());
    }

    /// @notice Earliest timestamp at which the next `reportLoss` is accepted; 0 when nothing was reported yet.
    function nextLossAllowedAt() external view returns (uint256) {
        return _nextLossAllowedAt(_getStakedTrUSDStorage());
    }

    function version() external pure returns (string memory) {
        return "1.1.0";
    }

    /* ------------- INTERNAL ------------- */
    /// @dev Reverts unless LOSS_INTERVAL has passed since the last report and `amount` fits under the cap,
    ///      then starts the next interval.
    function _consumeDailyLossCap(StakedTrUSDStorage storage $, uint256 amount) internal {
        uint256 nextAllowedAt = _nextLossAllowedAt($);
        if (block.timestamp < nextAllowedAt) revert LossReportTooSoon(nextAllowedAt);
        uint256 remaining = _remainingDailyLoss($);
        if (amount > remaining) revert DailyLossCapExceeded(amount, remaining);
        $.lastLossTimestamp = block.timestamp;
    }

    function _remainingDailyLoss(StakedTrUSDStorage storage $) internal view returns (uint256) {
        if (block.timestamp < _nextLossAllowedAt($)) return 0;
        return (totalAssets() * MAX_DAILY_LOSS_BPS) / BPS_DENOMINATOR;
    }

    function _nextLossAllowedAt(StakedTrUSDStorage storage $) internal view returns (uint256) {
        uint256 last = $.lastLossTimestamp;
        return last == 0 ? 0 : last + LOSS_INTERVAL;
    }

    function _updateVestingAmount(uint256 newAmount) internal {
        if (getUnvestedAmount() > 0) revert StillVesting();

        StakedTrUSDStorage storage $ = _getStakedTrUSDStorage();
        $.vestingAmount = newAmount;
        $.lastDistributionTimestamp = block.timestamp;
    }

    function _checkMinShares() internal view {
        uint256 _totalSupply = totalSupply();
        if (_totalSupply > 0 && _totalSupply < MIN_SHARES) revert MinSharesViolation();
    }

    function _deposit(
        address caller,
        address receiver,
        uint256 assets,
        uint256 shares
    )
        internal
        override
        nonReentrant
        notZero(assets)
        notZero(shares)
    {
        if (hasRole(FULL_RESTRICTED_STAKER_ROLE, caller) || hasRole(FULL_RESTRICTED_STAKER_ROLE, receiver)) {
            revert OperationNotAllowed();
        }
        super._deposit(caller, receiver, assets, shares);
        _checkMinShares();
    }

    function _withdraw(
        address caller,
        address receiver,
        address _owner,
        uint256 assets,
        uint256 shares
    )
        internal
        override
        nonReentrant
        notZero(assets)
        notZero(shares)
    {
        if (
            hasRole(FULL_RESTRICTED_STAKER_ROLE, caller) || hasRole(FULL_RESTRICTED_STAKER_ROLE, receiver)
                || hasRole(FULL_RESTRICTED_STAKER_ROLE, _owner)
        ) {
            revert OperationNotAllowed();
        }

        super._withdraw(caller, receiver, _owner, assets, shares);
        _checkMinShares();
    }

    function _update(address from, address to, uint256 amount) internal virtual override {
        if (hasRole(FULL_RESTRICTED_STAKER_ROLE, from) && to != address(0)) {
            revert OperationNotAllowed();
        }
        if (hasRole(FULL_RESTRICTED_STAKER_ROLE, to)) {
            revert OperationNotAllowed();
        }
        super._update(from, to, amount);
    }

    function renounceRole(bytes32, address) public virtual override {
        revert OperationNotAllowed();
    }

    /**
     * @notice Initialize the timelock admin - can only be called once by DEFAULT_ADMIN
     * @param timelockAdmin Address of the timelock contract
     * @dev This bootstraps the TIMELOCK_ADMIN_ROLE for the first time
     */
    function initializeTimelockAdmin(address timelockAdmin) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (timelockAdmin == address(0)) revert InvalidZeroAddress();
        StakedTrUSDStorage storage $ = _getStakedTrUSDStorage();
        if ($.timelockAdminInitialized) revert TimelockAdminAlreadyInitialized();

        $.timelockAdminInitialized = true;
        _grantRole(TIMELOCK_ADMIN_ROLE, timelockAdmin);
        emit TimelockAdminUpdated(address(0), timelockAdmin);
    }

    /**
     * @notice Set a new timelock admin - must be called via timelock
     * @param newTimelockAdmin New timelock admin address
     * @dev This is the ONLY way to change TIMELOCK_ADMIN_ROLE after initialization
     */
    function setTimelockAdmin(address newTimelockAdmin) external onlyRole(TIMELOCK_ADMIN_ROLE) {
        if (newTimelockAdmin == address(0)) revert InvalidZeroAddress();

        address currentAdmin = msg.sender;

        _revokeRole(TIMELOCK_ADMIN_ROLE, currentAdmin);
        _grantRole(TIMELOCK_ADMIN_ROLE, newTimelockAdmin);

        emit TimelockAdminUpdated(currentAdmin, newTimelockAdmin);
    }

    /**
     * @dev Override grantRole to block direct TIMELOCK_ADMIN_ROLE grants
     */
    function grantRole(bytes32 role, address account) public virtual override {
        if (role == TIMELOCK_ADMIN_ROLE) revert UseSetTimelockAdmin();
        super.grantRole(role, account);
    }

    /**
     * @dev Override revokeRole to block direct TIMELOCK_ADMIN_ROLE revocations
     */
    function revokeRole(bytes32 role, address account) public virtual override {
        if (role == TIMELOCK_ADMIN_ROLE) revert UseSetTimelockAdmin();
        super.revokeRole(role, account);
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyRole(TIMELOCK_ADMIN_ROLE) { }
}
