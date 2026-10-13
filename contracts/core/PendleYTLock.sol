// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlDefaultAdminRulesUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "../interfaces/IPendleYieldToken.sol";

/**
 * @title PendleYTLock
 * @notice ERC4626 vault for locking Pendle YT tokens, with withdrawal control and yield distribution
 * @dev YT tokens are held by this contract; deployed once per Pendle YT market
 * @dev Pendle credits the locked YT's interest to this contract as SY. It is attributed to share
 *      holders through a cumulative per-share index, and a claim redeems that SY 1:1 into
 *      `SY.yieldToken()`.
 * @dev Every share balance change goes through `_update`, which harvests first, so supply and balances
 *      are constant between harvests and a pro-rata split of each window is time-weighted.
 * @dev Mints and transfers harvest strictly; withdrawals and `claimYield` do not.
 */
contract PendleYTLock is
    Initializable,
    AccessControlDefaultAdminRulesUpgradeable,
    ReentrancyGuardUpgradeable,
    PausableUpgradeable,
    ERC20PermitUpgradeable,
    ERC4626Upgradeable,
    UUPSUpgradeable
{
    using SafeERC20 for IERC20;

    /* ------------- CONSTANTS ------------- */
    bytes32 public constant TIMELOCK_ADMIN_ROLE = keccak256("TIMELOCK_ADMIN_ROLE");

    /// @dev Fixed-point scale of `yieldIndex`. 1e27 keeps per-harvest truncation at sub-wei even for
    ///      a supply in the millions, while leaving the index far from overflow.
    uint256 private constant YIELD_INDEX_PRECISION = 1e27;

    /* ------------- STORAGE ------------- */
    struct PendleYTLockStorage {
        bool withdrawalsPaused;
        bool timelockAdminInitialized;
        uint256 totalDepositedAssets; // Track deposits separately from contract balance
        // --- v3: yield distribution. Appended only; never reorder the fields above. ---
        address syToken; // Pendle SY paired with the YT asset
        address yieldTokenAddress; // Token lockers are paid in, i.e. SY.yieldToken()
        uint256 yieldIndex; // Cumulative SY per share, scaled by YIELD_INDEX_PRECISION
        uint256 reservedYieldAmount; // SY already attributed to users and not yet claimed
        uint256 totalYieldHarvestedAmount;
        uint256 totalYieldClaimedAmount;
        mapping(address => uint256) userYieldIndex;
        mapping(address => uint256) userYieldAccrued;
        uint256 orphanedYieldAmount; // SY that arrived with no shares outstanding; not attributable
    }

    // ERC7201 namespaced storage location
    bytes32 private constant PENDLE_YT_LOCK_STORAGE_LOCATION =
        0x5c6d7e8f9a0b1c2d3e4f5a6b7c8d9e0f1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c02;

    function _getPendleYTLockStorage() private pure returns (PendleYTLockStorage storage $) {
        assembly {
            $.slot := PENDLE_YT_LOCK_STORAGE_LOCATION
        }
    }

    /* ------------- EVENTS ------------- */
    event WithdrawalsPaused(address indexed by);
    event WithdrawalsUnpaused(address indexed by);
    event TimelockAdminUpdated(address indexed oldTimelockAdmin, address indexed newTimelockAdmin);
    event YieldDistributionInitialized(address indexed syToken, address indexed yieldToken);
    event YieldHarvested(address indexed caller, uint256 amount, uint256 newYieldIndex);
    event YieldClaimed(address indexed account, address indexed receiver, uint256 amount);
    event PendleRewardsClaimed(address indexed caller);
    event OrphanYieldRescued(address indexed to, uint256 amount);
    /// @dev Emitted when a harvest finds SY with no shares outstanding to attribute it to; `amount` is
    ///      what this harvest added to `orphanedYield()`, not the running total
    event YieldQuarantined(uint256 amount);
    /// @dev Emitted when a best-effort harvest on the burn path could not reach Pendle
    event PendleInterestClaimFailed();

    /* ------------- ERRORS ------------- */
    error WithdrawalsArePaused();
    error InvalidZeroAddress();
    error InvalidAmount();
    error OperationNotAllowed();
    error UseSetTimelockAdmin();
    error TimelockAdminAlreadyInitialized();
    error YieldDistributionNotInitialized();
    error InvalidYieldToken();
    error NoYieldToClaim();
    error UnauthorizedCaller();

    /* ------------- MODIFIERS ------------- */
    modifier notZero(uint256 amount) {
        if (amount == 0) revert InvalidAmount();
        _;
    }

    modifier whenWithdrawalsNotPaused() {
        PendleYTLockStorage storage $ = _getPendleYTLockStorage();
        if ($.withdrawalsPaused) revert WithdrawalsArePaused();
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /* ------------- INITIALIZER ------------- */
    /**
     * @notice Initialize the vault
     * @param _asset Address of the Pendle YT token
     * @param _owner Initial owner address
     * @param _name ERC20 name of the lock share token
     * @param _symbol ERC20 symbol of the lock share token
     */
    function initialize(address _asset, address _owner, string memory _name, string memory _symbol) public initializer {
        if (_owner == address(0) || _asset == address(0)) {
            revert InvalidZeroAddress();
        }

        __AccessControlDefaultAdminRules_init(1 days, _owner);
        __ReentrancyGuard_init();
        __Pausable_init();
        __ERC20_init(_name, _symbol);
        __ERC20Permit_init(_name);
        __ERC4626_init(IERC20(_asset));
        __UUPSUpgradeable_init();

        PendleYTLockStorage storage $ = _getPendleYTLockStorage();
        $.withdrawalsPaused = true; // Paused by default

        // Fresh deployments are self-configuring, so deposits never depend on a follow-up call.
        _pinYieldTokens();
    }

    /**
     * @notice Pin the Pendle SY and the payout token, enabling yield distribution
     * @dev Only the proxies that predate v3 need this; run it as the `upgradeToAndCall` payload.
     *      The yield functions, and the harvest inside `_update`, require it.
     * @dev DEFAULT_ADMIN_ROLE or TIMELOCK_ADMIN_ROLE. Both addresses are re-derived from Pendle, so it
     *      cannot be aimed at an arbitrary token.
     */
    function initializeYieldDistribution() external reinitializer(2) {
        if (!hasRole(DEFAULT_ADMIN_ROLE, msg.sender) && !hasRole(TIMELOCK_ADMIN_ROLE, msg.sender)) {
            revert UnauthorizedCaller();
        }
        _pinYieldTokens();
    }

    /**
     * @notice Derive and store the Pendle SY and the payout token for the locked YT
     * @dev Stored rather than read from Pendle on demand: a Pendle-side SY upgrade must not be able to
     *      change the unit that `reservedYield()` is denominated in.
     */
    function _pinYieldTokens() private {
        address sy = IPendleYieldToken(asset()).SY();
        if (sy == address(0)) revert InvalidZeroAddress();

        address rewardToken = IPendleStandardizedYield(sy).yieldToken();
        // The payout token must be distinct from the locked YT, or a harvest would hand out principal.
        if (rewardToken == address(0) || rewardToken == asset()) revert InvalidYieldToken();
        if (!IPendleStandardizedYield(sy).isValidTokenOut(rewardToken)) revert InvalidYieldToken();
        // Accounting is denominated in SY and a claim redeems it 1:1, so a market whose payout leg is
        // not a plain wrapper must fail here rather than at the first claim.
        uint256 probe = 10 ** IERC20Metadata(rewardToken).decimals();
        if (IPendleStandardizedYield(sy).previewRedeem(rewardToken, probe) != probe) revert InvalidYieldToken();

        PendleYTLockStorage storage $ = _getPendleYTLockStorage();
        // The pinned pair is the unit every booked claim is denominated in and the pair `rescueTokens`
        // protects. A re-pin may confirm it, never move it.
        address pinned = $.yieldTokenAddress;
        if (pinned != address(0) && (pinned != rewardToken || $.syToken != sy)) revert InvalidYieldToken();
        $.syToken = sy;
        $.yieldTokenAddress = rewardToken;

        emit YieldDistributionInitialized(sy, rewardToken);
    }

    /* ------------- YIELD DISTRIBUTION ------------- */

    /**
     * @notice Harvest Pendle interest into this contract and attribute it to share holders
     * @return distributed Amount of SY newly attributed
     * @dev Permissionless, and callable while paused: it only pulls value in.
     */
    function claimPendleYield() external nonReentrant returns (uint256 distributed) {
        return _harvest(true);
    }

    /**
     * @notice Pull Pendle reward tokens (as opposed to interest) into this contract
     * @dev `getRewardTokens()` is empty on both markets today; this exists so a future stream cannot
     *      strand at Pendle.
     * @dev The pinned SY is absorbed by the next harvest and goes to lockers. Any other token has no
     *      per-user index and is handled with `rescueTokens`.
     */
    function claimPendleRewards()
        external
        nonReentrant
        onlyRole(DEFAULT_ADMIN_ROLE)
        returns (uint256[] memory rewardsOut)
    {
        (, rewardsOut) = IPendleYieldToken(asset()).redeemDueInterestAndRewards(address(this), false, true);
        emit PendleRewardsClaimed(msg.sender);
    }

    /**
     * @notice Sweep yield that has nobody to attribute it to
     * @param to Recipient of the orphaned yield
     * @dev Moves only `orphanedYield()`. Booked claims sit in `reservedYield` and are never part of it.
     * @dev Harvests first, and pays out in the payout token redeemed straight to `to`.
     */
    function rescueOrphanYield(address to) external nonReentrant onlyRole(DEFAULT_ADMIN_ROLE) {
        if (to == address(0) || to == address(this)) revert InvalidZeroAddress();

        PendleYTLockStorage storage $ = _getPendleYTLockStorage();
        address rewardToken = $.yieldTokenAddress;
        if (rewardToken == address(0)) revert YieldDistributionNotInitialized();

        // Best-effort: an unreachable Pendle must not block the release of value already sitting here.
        _harvest(false);

        uint256 orphaned = $.orphanedYieldAmount;
        if (orphaned == 0) revert NoYieldToClaim();
        $.orphanedYieldAmount = 0;

        IPendleStandardizedYield($.syToken).redeem(to, orphaned, rewardToken, orphaned, false);

        emit OrphanYieldRescued(to, orphaned);
    }

    /**
     * @notice Claim your accrued yield
     * @dev Intentionally NOT gated on `withdrawalsPaused` — collecting yield while the YT itself stays
     *      locked is the point of the feature. It is gated on the emergency `pause()`.
     * @dev Does not harvest, so it keeps working through a Pendle-side outage. Call
     *      `claimPendleYield()` first (front-ends batch the two) to include the freshest accrual.
     */
    function claimYield() external nonReentrant whenNotPaused returns (uint256 amount) {
        return _claimYield(msg.sender, msg.sender);
    }

    /**
     * @notice Claim your accrued yield to a different address
     * @param receiver Address to receive the yield token
     */
    function claimYieldTo(address receiver) external nonReentrant whenNotPaused returns (uint256 amount) {
        return _claimYield(msg.sender, receiver);
    }

    /* ------------- EXTERNAL FUNCTIONS ------------- */

    /**
     * @notice Pause all withdrawals and redemptions
     * @dev Only callable by TIMELOCK_ADMIN_ROLE (via timelock)
     */
    function pauseWithdrawals() external onlyRole(TIMELOCK_ADMIN_ROLE) {
        PendleYTLockStorage storage $ = _getPendleYTLockStorage();
        $.withdrawalsPaused = true;
        emit WithdrawalsPaused(msg.sender);
    }

    /**
     * @notice Unpause withdrawals and redemptions
     * @dev TIMELOCK_ADMIN_ROLE or DEFAULT_ADMIN_ROLE. Pausing stays timelock-only.
     */
    function unpauseWithdrawals() external {
        if (!hasRole(TIMELOCK_ADMIN_ROLE, msg.sender) && !hasRole(DEFAULT_ADMIN_ROLE, msg.sender)) {
            revert UnauthorizedCaller();
        }
        PendleYTLockStorage storage $ = _getPendleYTLockStorage();
        $.withdrawalsPaused = false;
        emit WithdrawalsUnpaused(msg.sender);
    }

    /**
     * @notice Emergency pause - stops deposits, withdrawals and yield claims
     * @dev Only callable by DEFAULT_ADMIN_ROLE
     * @dev Distinct from `withdrawalsPaused`, which blocks only withdraw/redeem and leaves
     *      `claimYield` working. This one also stops claiming. Share transfers are not gated.
     */
    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }

    /**
     * @notice Unpause contract - re-allows deposits, withdrawals and yield claims
     * @dev Only callable by DEFAULT_ADMIN_ROLE
     */
    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    /**
     * @notice Rescue tokens accidentally sent to this contract
     * @param token Token address to rescue
     * @param amount Amount to rescue
     * @param to Recipient address
     * @dev Cannot rescue the locked YT or the Pendle SY: those are the locked principal and the unit
     *      `reservedYield()` is denominated in.
     */
    function rescueTokens(address token, uint256 amount, address to)
        external
        nonReentrant
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        PendleYTLockStorage storage $ = _getPendleYTLockStorage();
        if (token == address(0)) revert InvalidZeroAddress();
        // Lockers' value is the SY the reserve is denominated in, and the locked YT. The payout token is
        // neither: claims redeem SY straight to the claimant, so none of it rests here.
        if (token == asset() || token == $.syToken) {
            revert OperationNotAllowed();
        }
        if (to == address(0)) revert InvalidZeroAddress();
        IERC20(token).safeTransfer(to, amount);
    }

    /* ------------- OVERRIDDEN ERC4626 FUNCTIONS ------------- */

    /**
     * @notice Maximum amount of assets that can be deposited
     * @dev Returns 0 when the contract is emergency-paused (EIP-4626 compliance)
     */
    function maxDeposit(address owner) public view virtual override returns (uint256) {
        if (paused()) return 0;
        return super.maxDeposit(owner);
    }

    /**
     * @notice Maximum amount of shares that can be minted
     * @dev Returns 0 when the contract is emergency-paused (EIP-4626 compliance)
     */
    function maxMint(address owner) public view virtual override returns (uint256) {
        if (paused()) return 0;
        return super.maxMint(owner);
    }

    /**
     * @notice Withdraw assets from the vault
     * @dev Blocked when withdrawals are paused
     */
    function withdraw(
        uint256 assets,
        address receiver,
        address _owner
    )
        public
        virtual
        override
        whenWithdrawalsNotPaused
        returns (uint256)
    {
        return super.withdraw(assets, receiver, _owner);
    }

    /**
     * @notice Redeem shares from the vault
     * @dev Blocked when withdrawals are paused
     */
    function redeem(
        uint256 shares,
        address receiver,
        address _owner
    )
        public
        virtual
        override
        whenWithdrawalsNotPaused
        returns (uint256)
    {
        return super.redeem(shares, receiver, _owner);
    }

    /**
     * @notice Maximum amount of assets that can be withdrawn
     * @dev Returns 0 when withdrawals are paused
     */
    function maxWithdraw(address owner) public view virtual override returns (uint256) {
        PendleYTLockStorage storage $ = _getPendleYTLockStorage();
        if ($.withdrawalsPaused || paused()) {
            return 0;
        }
        return super.maxWithdraw(owner);
    }

    /**
     * @notice Maximum amount of shares that can be redeemed
     * @dev Returns 0 when withdrawals are paused
     */
    function maxRedeem(address owner) public view virtual override returns (uint256) {
        PendleYTLockStorage storage $ = _getPendleYTLockStorage();
        if ($.withdrawalsPaused || paused()) {
            return 0;
        }
        return super.maxRedeem(owner);
    }

    /**
     * @notice Calculate total assets under management
     * @dev Returns tracked deposited assets (donation-proof, ignores direct transfers)
     */
    function totalAssets() public view override returns (uint256) {
        PendleYTLockStorage storage $ = _getPendleYTLockStorage();
        return $.totalDepositedAssets;
    }

    /* ------------- VIEW FUNCTIONS ------------- */

    /**
     * @notice Check if withdrawals are currently paused
     */
    function withdrawalsPaused() external view returns (bool) {
        PendleYTLockStorage storage $ = _getPendleYTLockStorage();
        return $.withdrawalsPaused;
    }

    /**
     * @notice Get user's share balance
     */
    function getUserShares(address user) external view returns (uint256) {
        return balanceOf(user);
    }

    /**
     * @notice Payout token a user can claim right now, including accrual not yet written to storage
     * @dev Excludes interest still sitting at Pendle. Call `claimPendleYield()` first for a total.
     * @dev Booked in SY, paid 1:1, so the number is the same in either unit.
     */
    function claimableYield(address user) public view returns (uint256) {
        PendleYTLockStorage storage $ = _getPendleYTLockStorage();
        uint256 amount = $.userYieldAccrued[user];
        uint256 index = $.yieldIndex;
        uint256 userIndex = $.userYieldIndex[user];
        if (index != userIndex) {
            amount += (balanceOf(user) * (index - userIndex)) / YIELD_INDEX_PRECISION;
        }
        return amount;
    }

    /// @notice Token lockers are paid their yield in — the underlying SY's `yieldToken()`
    function yieldToken() external view returns (address) {
        return _getPendleYTLockStorage().yieldTokenAddress;
    }

    /// @notice Pendle SY paired with the locked YT; interest arrives denominated in it
    function syToken() external view returns (address) {
        return _getPendleYTLockStorage().syToken;
    }

    /// @notice Cumulative yield per share, scaled by 1e27
    function yieldIndex() external view returns (uint256) {
        return _getPendleYTLockStorage().yieldIndex;
    }

    /// @notice SY already attributed to users and not yet claimed
    function reservedYield() external view returns (uint256) {
        return _getPendleYTLockStorage().reservedYieldAmount;
    }

    /// @notice Lifetime yield attributed to users
    function totalYieldHarvested() external view returns (uint256) {
        return _getPendleYTLockStorage().totalYieldHarvestedAmount;
    }

    /// @notice Lifetime yield claimed by users
    function totalYieldClaimed() external view returns (uint256) {
        return _getPendleYTLockStorage().totalYieldClaimedAmount;
    }

    /// @notice SY held here that no share can claim, awaiting `rescueOrphanYield`
    function orphanedYield() external view returns (uint256) {
        return _getPendleYTLockStorage().orphanedYieldAmount;
    }

    /**
     * @notice SY sitting here that the next harvest will attribute
     * @dev Non-zero when a third party pushed Pendle interest here, or someone donated SY. Excludes
     *      `orphanedYield()`, which no harvest will attribute.
     */
    function pendingYieldToDistribute() external view returns (uint256) {
        PendleYTLockStorage storage $ = _getPendleYTLockStorage();
        address sy = $.syToken;
        if (sy == address(0)) return 0;
        uint256 balance = IERC20(sy).balanceOf(address(this));
        uint256 committed = $.reservedYieldAmount + $.orphanedYieldAmount;
        return balance > committed ? balance - committed : 0;
    }

    /**
     * @notice Interest Pendle has checkpointed for this contract, in SY
     * @dev A lower bound: Pendle only checkpoints on interaction, so growth since the last checkpoint
     *      is not included. Use it for monitoring, not for accounting.
     */
    function pendingPendleInterest() external view returns (uint256) {
        (, uint128 accrued) = IPendleYieldToken(asset()).userInterest(address(this));
        return accrued;
    }

    /**
     * @notice Get contract version
     */
    function version() external pure returns (string memory) {
        return "3.0.0";
    }

    function decimals() public pure override(ERC4626Upgradeable, ERC20Upgradeable) returns (uint8) {
        return 18;
    }

    /* ------------- INTERNAL FUNCTIONS ------------- */

    /**
     * @notice Pull Pendle interest into this contract and fold it into `yieldIndex`
     * @param strict When true the call reverts on any Pendle-side failure; when false it degrades to
     *        indexing whatever is already here
     * @return distributed Amount newly attributed to share holders
     * @dev Step 2 measures the SY balance instead of trusting a return value, which is what makes
     *      third-party `redeemDueInterestAndRewards` calls and plain SY donations count too.
     */
    function _harvest(bool strict) private returns (uint256 distributed) {
        PendleYTLockStorage storage $ = _getPendleYTLockStorage();
        address sy = $.syToken;
        if (sy == address(0)) {
            // The burn path must stay open even if initialization was missed.
            if (strict) revert YieldDistributionNotInitialized();
            return 0;
        }

        // 1. Pendle pays this contract's accrued interest out in SY. Rewards are handled separately by
        //    claimPendleRewards() so an unexpected reward token cannot break the deposit path.
        if (strict) {
            IPendleYieldToken(asset()).redeemDueInterestAndRewards(address(this), true, false);
        } else {
            try IPendleYieldToken(asset()).redeemDueInterestAndRewards(address(this), true, false) { }
            catch {
                emit PendleInterestClaimFailed();
            }
        }

        // 2. Attribute everything that is here but not yet owed to a user. Accounting is denominated in
        //    SY, the unit Pendle pays interest in; the unwrap to the payout token happens per claim, so
        //    a payout-side failure cannot reach the share ledger.
        uint256 reserved = $.reservedYieldAmount;
        uint256 orphaned = $.orphanedYieldAmount;
        // Everything already spoken for: booked claims plus the quarantine below.
        uint256 committed = reserved + orphaned;
        uint256 balance = IERC20(sy).balanceOf(address(this));
        if (balance <= committed) return 0;

        uint256 supply = totalSupply();
        if (supply == 0) {
            // No shares outstanding, so any share minted from here on would postdate this. Quarantine
            // it so no later holder is paid it; `reservedYieldAmount` is left alone.
            $.orphanedYieldAmount = balance - reserved;
            emit YieldQuarantined(balance - reserved - orphaned);
            return 0;
        }

        uint256 indexDelta = ((balance - committed) * YIELD_INDEX_PRECISION) / supply;

        // What the index can actually pay out.
        uint256 payable_ = (indexDelta * supply) / YIELD_INDEX_PRECISION;
        // Too little to move the index by a payable amount — leave it pending rather than drifting it.
        if (payable_ == 0) return 0;

        // Reserve the ceiling, so the reserve covers every booking a settlement can produce regardless
        // of claim order. Bounded above by `balance - committed`, so it stays backed.
        distributed = payable_ * YIELD_INDEX_PRECISION == indexDelta * supply ? payable_ : payable_ + 1;

        $.yieldIndex += indexDelta;
        $.reservedYieldAmount = reserved + distributed;
        $.totalYieldHarvestedAmount += distributed;

        emit YieldHarvested(msg.sender, distributed, $.yieldIndex);
    }

    /**
     * @notice Book `account`'s share of the index growth since its last checkpoint
     * @dev Must run before the account's balance moves, which is why it hangs off `_update`.
     */
    function _settleYield(address account) private {
        PendleYTLockStorage storage $ = _getPendleYTLockStorage();
        uint256 index = $.yieldIndex;
        uint256 userIndex = $.userYieldIndex[account];
        if (userIndex == index) return;

        uint256 shares = balanceOf(account);
        if (shares != 0) {
            $.userYieldAccrued[account] += (shares * (index - userIndex)) / YIELD_INDEX_PRECISION;
        }
        $.userYieldIndex[account] = index;
    }

    /**
     * @notice Pay out an account's booked yield
     * @dev Survives a full exit: `userYieldAccrued` is not tied to holding shares.
     */
    function _claimYield(address account, address receiver) private returns (uint256 amount) {
        if (receiver == address(0)) revert InvalidZeroAddress();
        // Paying to the vault is a no-op self-transfer that would still zero the caller's booking,
        // handing their claim to the other holders at the next harvest.
        if (receiver == address(this)) revert OperationNotAllowed();

        PendleYTLockStorage storage $ = _getPendleYTLockStorage();
        address rewardToken = $.yieldTokenAddress;
        if (rewardToken == address(0)) revert YieldDistributionNotInitialized();

        _settleYield(account);

        uint256 booked = $.userYieldAccrued[account];
        if (booked == 0) revert NoYieldToClaim();
        $.userYieldAccrued[account] = 0;

        // Floor only; the per-harvest ceiling reserve keeps this cap out of reach.
        uint256 reserved = $.reservedYieldAmount;
        amount = booked > reserved ? reserved : booked;

        $.reservedYieldAmount = reserved - amount;
        $.totalYieldClaimedAmount += amount;

        if (amount != 0) {
            // Redeem this claim's SY straight to the receiver: the lock is never a party to a payout
            // token transfer. 1:1 is asserted at pin time, so `minTokenOut == amount` is exact.
            IPendleStandardizedYield($.syToken).redeem(receiver, amount, rewardToken, amount, false);
        }

        emit YieldClaimed(account, receiver, amount);
    }

    /**
     * @notice Harvest and settle before any balance moves. The single choke point for mint, burn and
     *         transfer, and the reason the pro-rata split is exactly time-weighted.
     * @dev Mints and transfers harvest strictly, so a stale index is never committed. On burns the
     *      Pendle interest claim is best-effort, so an unreachable Pendle does not block an exit.
     */
    function _update(address from, address to, uint256 value) internal override {
        // Shares held by the vault itself could never claim their slice of a later harvest.
        if (to == address(this)) revert OperationNotAllowed();

        // No balance moves, so there is no window to time-weight and no checkpoint that has to advance.
        // Settlement stays tied to an actual balance change.
        if (value == 0) {
            super._update(from, to, value);
            return;
        }

        _harvest(to != address(0));

        if (from != address(0)) _settleYield(from);
        if (to != address(0)) _settleYield(to);
        super._update(from, to, value);
    }

    /**
     * @notice Internal deposit override
     * @dev YT stays in this contract
     * @dev Blocked when contract is paused (emergency)
     */
    function _deposit(
        address caller,
        address receiver,
        uint256 assets,
        uint256 shares
    )
        internal
        override
        whenNotPaused
        nonReentrant
        notZero(assets)
        notZero(shares)
    {
        PendleYTLockStorage storage $ = _getPendleYTLockStorage();

        // Track deposited assets
        $.totalDepositedAssets += assets;

        // `_update` harvests strictly before these shares exist, which is what stops a depositor from
        // front-running a harvest and taking a slice of yield the existing YT earned.
        _mint(receiver, shares);

        // Transfer YT from user to this contract
        IERC20(asset()).safeTransferFrom(caller, address(this), assets);

        emit Deposit(caller, receiver, assets, shares);
    }

    /**
     * @notice Internal withdraw override
     * @dev Transfers YT held by this contract
     * @dev Blocked when contract is paused (emergency)
     */
    function _withdraw(
        address caller,
        address receiver,
        address _owner,
        uint256 assets,
        uint256 shares
    )
        internal
        override
        whenNotPaused
        nonReentrant
        notZero(assets)
        notZero(shares)
    {
        // YT sent back into the lock is unrecoverable: `totalDepositedAssets` drops but the token
        // stays, and `rescueTokens` refuses `asset()`.
        if (receiver == address(this)) revert OperationNotAllowed();

        PendleYTLockStorage storage $ = _getPendleYTLockStorage();

        // No harvest here: `_burn` below routes through `_update`, which harvests best-effort and
        // credits the exiting owner. Harvesting again at this level would be a second Pendle round-trip
        // per exit, and two call sites would each look removable because the other appeared to cover it.

        // Spend allowance if needed
        if (caller != _owner) {
            _spendAllowance(_owner, caller, shares);
        }

        // Track withdrawn assets
        $.totalDepositedAssets -= assets;

        // Burn shares
        _burn(_owner, shares);

        // Transfer YT from this contract to receiver
        IERC20(asset()).safeTransfer(receiver, assets);

        emit Withdraw(caller, receiver, _owner, assets, shares);
    }

    /**
     * @notice Block role renouncement
     */
    function renounceRole(bytes32, address) public virtual override {
        revert OperationNotAllowed();
    }

    /* ------------- TIMELOCK ADMIN FUNCTIONS ------------- */

    /**
     * @notice Initialize the timelock admin - can only be called once
     * @param timelockAdmin Address of the timelock contract
     */
    function initializeTimelockAdmin(address timelockAdmin) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (timelockAdmin == address(0)) revert InvalidZeroAddress();
        PendleYTLockStorage storage $ = _getPendleYTLockStorage();
        if ($.timelockAdminInitialized) revert TimelockAdminAlreadyInitialized();

        $.timelockAdminInitialized = true;
        _grantRole(TIMELOCK_ADMIN_ROLE, timelockAdmin);
        emit TimelockAdminUpdated(address(0), timelockAdmin);
    }

    /**
     * @notice Set a new timelock admin - must be called via timelock
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

    /**
     * @notice Authorize contract upgrades
     * @dev Only TIMELOCK_ADMIN_ROLE can authorize upgrades
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(TIMELOCK_ADMIN_ROLE) { }
}
