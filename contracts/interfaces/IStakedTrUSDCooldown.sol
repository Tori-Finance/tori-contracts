// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "./IStakedTrUSD.sol";

struct UserCooldown {
    uint104 cooldownEnd;
    uint256 underlyingAmount;
}

interface IStakedTrUSDCooldown is IStakedTrUSD {
    // Events //
    /// @notice Event emitted when cooldown duration updates
    event CooldownDurationUpdated(uint24 previousDuration, uint24 newDuration);
    /// @notice Event emitted when the silo address updates
    event SiloUpdated(address previousSilo, address newSilo);
    /// @notice Event emitted when a user cancels their cooldown
    event CooldownCancelled(address indexed user, uint256 assets, uint256 shares);

    // Errors //
    /// @notice Error emitted when the shares amount to redeem is greater than the shares balance of the owner
    error ExcessiveRedeemAmount();
    /// @notice Error emitted when the shares amount to withdraw is greater than the shares balance of the owner
    error ExcessiveWithdrawAmount();
    /// @notice Error emitted when cooldown value is invalid
    error InvalidCooldown();

    function cooldownAssets(uint256 assets) external returns (uint256 shares);

    function cooldownShares(uint256 shares) external returns (uint256 assets);

    function unstake(address receiver) external;

    function cancelCooldown() external;

    function setCooldownDuration(uint24 duration) external;
}
