// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

/**
 * @title IPendleYieldToken
 * @notice Minimal view of Pendle V2's PendleYieldToken, limited to what PendleYTLock needs
 * @dev Matches Pendle V2's verified mainnet sources.
 */
interface IPendleYieldToken {
    /// @notice Standardized Yield token this YT is paired with; interest is paid out in it
    function SY() external view returns (address);

    /// @notice Principal token this YT is paired with
    function PT() external view returns (address);

    /// @notice Unix timestamp at which the YT stops accruing
    function expiry() external view returns (uint256);

    /// @notice True once `block.timestamp >= expiry()`
    function isExpired() external view returns (bool);

    /**
     * @notice Pushes `user`'s accrued interest (in SY) and reward tokens to `user`
     * @dev Permissionless in Pendle — there is no `msg.sender == user` check, so anyone may
     *      trigger a payout to the lock contract. Accounting must therefore never rely on the
     *      return value of this call and must measure balances instead.
     * @dev Pendle takes `IPYieldContractFactory.interestFeeRate()` off the interest before transfer.
     */
    function redeemDueInterestAndRewards(
        address user,
        bool redeemInterest,
        bool redeemRewards
    )
        external
        returns (uint256 interestOut, uint256[] memory rewardsOut);

    /// @notice Reward tokens streamed by the underlying SY; empty on markets that stream none
    function getRewardTokens() external view returns (address[] memory);

    /// @notice Last checkpointed interest state for `user`; `accrued` excludes growth since the checkpoint
    function userInterest(address user) external view returns (uint128 index, uint128 accrued);
}

/**
 * @title IPendleStandardizedYield
 * @notice Minimal view of Pendle V2's SYBaseUpg, limited to what PendleYTLock needs
 */
interface IPendleStandardizedYield {
    /// @notice The token SY shares are backed by 1:1
    function yieldToken() external view returns (address);

    /**
     * @notice Burns SY from `msg.sender` and sends `tokenOut` to `receiver`
     * @dev No allowance needed — SYBaseUpg burns from `msg.sender` directly.
     * @dev When `tokenOut == yieldToken()` the payout is exactly 1:1 with no fee and no rounding.
     * @dev Reverts on a zero `amountSharesToRedeem` and while SY is paused.
     */
    function redeem(
        address receiver,
        uint256 amountSharesToRedeem,
        address tokenOut,
        uint256 minTokenOut,
        bool burnFromInternalBalance
    )
        external
        returns (uint256 amountTokenOut);

    /// @notice Whether `token` is an accepted `tokenOut` for `redeem`
    function isValidTokenOut(address token) external view returns (bool);

    /// @notice Quotes `redeem` without executing it
    function previewRedeem(address tokenOut, uint256 amountSharesToRedeem) external view returns (uint256);
}
