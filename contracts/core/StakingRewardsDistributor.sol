// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";

import "../interfaces/IStakedTrUSD.sol";

/**
 * @title StakingRewardsDistributor
 * @notice This helper contract allows us to distribute staking rewards without the need of multisig transactions.
 * It increases the distribution frequency and automates almost the whole process, we also mitigate some arbitrage
 * opportunities with this approach.
 * @dev We have two roles:
 *      - The owner of this helper will be the multisig, only used for configuration calls.
 *      - The operator will be the delegated signer and is only allowed to call transferInRewards to send
 *        TrUSD rewards to the staking contract. The operator can be replaced by the owner at any time with
 *        a single transaction.
 */
contract StakingRewardsDistributor is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ---------------------- Constants -----------------------
    /// @notice placeholder address for ETH
    address internal constant _ETH_ADDRESS = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    // ---------------------- Immutables -----------------------
    /// @notice Tori staking contract
    IStakedTrUSD public immutable STAKING_VAULT;
    /// @notice Tori TrUSD stablecoin
    IERC20 public immutable TRUSD_TOKEN;

    // ---------------------- Storage --------------------------
    /// @notice only address authorized to invoke transferInRewards
    address public operator;

    // ---------------------- Events ---------------------------
    event TokensRescued(address indexed token, address indexed to, uint256 amount);
    event OperatorUpdated(address indexed newOperator, address indexed oldOperator);
    event RewardsDistributed(uint256 indexed amount, address indexed operator, uint256 timestamp);
    event LossReported(uint256 indexed amount, address indexed operator, uint256 timestamp);
    event ApprovalUpdated(address indexed spender, uint256 amount);
    event ApprovalRevoked(address indexed spender);

    // ---------------------- Errors ---------------------------
    error InvalidZeroAddress();
    error OnlyOperator();
    error InsufficientFunds();
    error InvalidAmount();
    error TransferFailed();
    error CantRenounceOwnership();
    error CannotRescueRewardToken();
    error NotAContract();
    error InvalidStakingVault();
    error OperatorUnchanged();

    constructor(IStakedTrUSD _staking_vault, IERC20 _trusd, address _admin, address _operator) Ownable(_admin) {
        if (address(_staking_vault) == address(0)) revert InvalidZeroAddress();
        if (address(_trusd) == address(0)) revert InvalidZeroAddress();
        if (address(_admin) == address(0)) revert InvalidZeroAddress();
        if (address(_operator) == address(0)) revert InvalidZeroAddress();

        if (address(_staking_vault).code.length == 0) revert NotAContract();

        try _staking_vault.getUnvestedAmount() returns (uint256) { }
        catch {
            revert InvalidStakingVault();
        }

        STAKING_VAULT = _staking_vault;
        TRUSD_TOKEN = _trusd;

        operator = _operator;
        emit OperatorUpdated(_operator, address(0));

        IERC20(address(TRUSD_TOKEN)).safeIncreaseAllowance(address(STAKING_VAULT), type(uint256).max);

        if (msg.sender != _admin) {
            _transferOwnership(_admin);
        }
    }

    /**
     * @notice only the operator can call transferInRewards in order to transfer TrUSD to the staking contract
     * @param _rewardsAmount the amount of TrUSD to send
     * @dev In order to use this function, we need to set this contract as the REWARDER_ROLE in the staking contract
     */
    function transferInRewards(uint256 _rewardsAmount) external nonReentrant {
        if (msg.sender != operator) revert OnlyOperator();
        if (_rewardsAmount == 0) revert InvalidAmount();
        if (TRUSD_TOKEN.balanceOf(address(this)) < _rewardsAmount) revert InsufficientFunds();

        STAKING_VAULT.transferInRewards(_rewardsAmount);

        emit RewardsDistributed(_rewardsAmount, msg.sender, block.timestamp);
    }

    /**
     * @notice only the operator can call reportLoss to report a loss to the staking contract
     * @param _lossAmount the amount of TrUSD loss to report
     * @dev In order to use this function, we need to set this contract as the REWARDER_ROLE in the staking contract
     */
    function reportLoss(uint256 _lossAmount) external nonReentrant {
        if (msg.sender != operator) revert OnlyOperator();
        if (_lossAmount == 0) revert InvalidAmount();

        STAKING_VAULT.reportLoss(_lossAmount);

        emit LossReported(_lossAmount, msg.sender, block.timestamp);
    }

    /**
     * @notice owner can rescue tokens that were accidentally sent to the contract
     * @param _token the token to transfer
     * @param _to the address to send the tokens to
     * @param _amount the amount of tokens to send
     * @dev only available for the owner
     */
    function rescueTokens(address _token, address _to, uint256 _amount) external nonReentrant onlyOwner {
        if (_token == address(0)) revert InvalidZeroAddress();
        if (_token == address(TRUSD_TOKEN)) revert CannotRescueRewardToken();
        if (_to == address(0)) revert InvalidZeroAddress();
        if (_amount == 0) revert InvalidAmount();

        // Contract can only receive ETH via selfdestruct, allow rescuing it
        if (_token == _ETH_ADDRESS) {
            (bool success,) = _to.call{ value: _amount }("");
            if (!success) revert TransferFailed();
        } else {
            IERC20(_token).safeTransfer(_to, _amount);
        }
        emit TokensRescued(_token, _to, _amount);
    }

    /**
     * @notice sets a new operator
     * @param _newOperator new operator address
     * @dev only available for the owner. We allow the address(0) as a new operator
     * in case that the key is exposed and we just want to remove the current operator
     * as soon as possible being able to set to 0
     */
    function setOperator(address _newOperator) public onlyOwner {
        if (_newOperator == operator) revert OperatorUnchanged();

        address oldOperator = operator;
        operator = _newOperator;

        emit OperatorUpdated(_newOperator, oldOperator);
    }

    /**
     * @notice allows owner to update TrUSD approval to staking vault
     * @param amount the new approval amount
     * @dev only available for the owner, useful if staking vault is compromised or needs updating
     */
    function updateStakingVaultApproval(uint256 amount) external onlyOwner {
        TRUSD_TOKEN.forceApprove(address(STAKING_VAULT), amount);
        emit ApprovalUpdated(address(STAKING_VAULT), amount);
    }

    /**
     * @notice emergency function to revoke all TrUSD approvals to staking vault
     * @dev only available for the owner, use if staking vault is compromised
     */
    function revokeStakingVaultApproval() external onlyOwner {
        TRUSD_TOKEN.forceApprove(address(STAKING_VAULT), 0);
        emit ApprovalRevoked(address(STAKING_VAULT));
    }

    /**
     * @notice prevents the owner from renouncing the owner role
     */
    function renounceOwnership() public view override onlyOwner {
        revert CantRenounceOwnership();
    }
}
