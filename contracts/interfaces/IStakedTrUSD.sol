// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

interface IStakedTrUSD {
    // Events //
    /// @notice Event emitted when the rewards are received
    event RewardsReceived(uint256 indexed amount);
    /// @notice Event emitted when the balance from an FULL_RESTRICTED_STAKER_ROLE user are redistributed
    event LockedAmountRedistributed(address indexed from, address indexed to, uint256 amount);
    /// @notice Event emitted when admin seizes cooldown assets from a blacklisted user
    event CooldownSeized(address indexed from, address indexed to, uint256 amount);

    // Errors //
    /// @notice Error emitted shares or assets equal zero.
    error InvalidAmount();
    /// @notice Error emitted when owner attempts to rescue TrUSD tokens.
    error InvalidToken();
    /// @notice Error emitted when slippage is exceeded on a deposit or withdrawal
    error SlippageExceeded();
    /// @notice Error emitted when a small non-zero share amount remains, which risks donations attack
    error MinSharesViolation();
    /// @notice Error emitted when owner is not allowed to perform an operation
    error OperationNotAllowed();
    /// @notice Error emitted when there is still unvested amount
    error StillVesting();
    /// @notice Error emitted when owner or blacklist manager attempts to blacklist owner
    error CantBlacklistOwner();
    /// @notice Error emitted when the zero address is given
    error InvalidZeroAddress();
    /// @notice Error emitted when there are no orphan funds to rescue
    error NoOrphanFunds();
    /// @notice Error emitted when attempting to use grantRole/revokeRole for TIMELOCK_ADMIN_ROLE
    error UseSetTimelockAdmin();
    /// @notice Error emitted when trying to initialize timelock admin more than once
    error TimelockAdminAlreadyInitialized();
    /// @notice reportLoss amount above the per-report cap (MAX_DAILY_LOSS_BPS of totalAssets)
    error DailyLossCapExceeded(uint256 requested, uint256 remaining);
    /// @notice reportLoss called before LOSS_INTERVAL has passed since the last accepted report
    error LossReportTooSoon(uint256 nextAllowedAt);

    /// @notice Event emitted when orphan funds are rescued
    event OrphanFundsRescued(address indexed to, uint256 amount);
    /// @notice Event emitted when the timelock admin is updated
    event TimelockAdminUpdated(address indexed oldTimelockAdmin, address indexed newTimelockAdmin);
    /// @notice Event emitted when a loss is reported and assets are burned
    event LossReported(uint256 indexed amount);

    function transferInRewards(uint256 amount) external;

    function reportLoss(uint256 amount) external;

    function rescueTokens(address token, uint256 amount, address to) external;

    function rescueOrphanFunds(address to) external;

    function getUnvestedAmount() external view returns (uint256);
}
