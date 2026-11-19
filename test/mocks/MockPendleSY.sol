// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title MockYieldToken
 * @notice Plain 18-decimal mintable ERC20, stands in for the SY's yield token in tests
 */
contract MockYieldToken is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) { }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/**
 * @title MockPendleSY
 * @notice Mock of Pendle V2's SYBaseUpg, modelling the behaviour PendleYTLock depends on
 * @dev Mirrors the mainnet contracts in the three ways that matter:
 *      - `redeem` with `tokenOut == yieldToken()` pays out exactly 1:1 with no fee
 *      - `redeem` burns from `msg.sender`, so no allowance is needed
 *      - `redeem` reverts on a zero amount, and everything reverts while paused
 */
contract MockPendleSY is ERC20 {
    address public immutable YIELD_TOKEN;
    bool public paused;

    error SYZeroRedeem();
    error SYInvalidTokenOut();
    error SYPaused();
    error SYInsufficientTokenOut();

    constructor(address yieldToken_) ERC20("Mock SY", "SY-mock") {
        YIELD_TOKEN = yieldToken_;
    }

    function yieldToken() external view returns (address) {
        return YIELD_TOKEN;
    }

    /// @notice Test hook: simulate Pendle no longer accepting the pinned token as a redemption target
    bool public rejectTokenOut;

    function isValidTokenOut(address token) external view returns (bool) {
        return !rejectTokenOut && token == YIELD_TOKEN;
    }

    /// @notice The single payout token, as SYBaseUpg reports it
    function getTokensOut() external view returns (address[] memory out) {
        out = new address[](1);
        out[0] = YIELD_TOKEN;
    }

    function setRejectTokenOut(bool rejectTokenOut_) external {
        rejectTokenOut = rejectTokenOut_;
    }

    /// @notice Test hook: an SY whose payout leg is not a plain 1:1 wrapper. 1e18 == par.
    uint256 public previewRedeemRate = 1e18;

    function setPreviewRedeemRate(uint256 previewRedeemRate_) external {
        previewRedeemRate = previewRedeemRate_;
    }

    function previewRedeem(address tokenOut, uint256 amountSharesToRedeem) external view returns (uint256) {
        if (tokenOut != YIELD_TOKEN) revert SYInvalidTokenOut();
        return (amountSharesToRedeem * previewRedeemRate) / 1e18;
    }

    /// @notice Test hook: simulate Pendle pausing SY, which blocks transfers and redemptions
    function setPaused(bool paused_) external {
        paused = paused_;
    }

    /// @notice Mint SY backed 1:1 by yield token pulled from the caller
    function mintFor(address to, uint256 amount) external {
        IERC20(YIELD_TOKEN).transferFrom(msg.sender, address(this), amount);
        _mint(to, amount);
    }

    function redeem(
        address receiver,
        uint256 amountSharesToRedeem,
        address tokenOut,
        uint256 minTokenOut,
        bool burnFromInternalBalance
    )
        external
        returns (uint256 amountTokenOut)
    {
        if (paused) revert SYPaused();
        if (tokenOut != YIELD_TOKEN) revert SYInvalidTokenOut();
        if (amountSharesToRedeem == 0) revert SYZeroRedeem();

        if (burnFromInternalBalance) {
            _burn(address(this), amountSharesToRedeem);
        } else {
            _burn(msg.sender, amountSharesToRedeem);
        }

        amountTokenOut = amountSharesToRedeem; // 1:1 for tokenOut == yieldToken
        if (amountTokenOut < minTokenOut) revert SYInsufficientTokenOut();

        IERC20(YIELD_TOKEN).transfer(receiver, amountTokenOut);
    }

    /// @dev Real SY gates transfers on `whenNotPaused`, which is why a paused SY also breaks a payout
    function _update(address from, address to, uint256 value) internal override {
        if (paused) revert SYPaused();
        super._update(from, to, value);
    }
}
