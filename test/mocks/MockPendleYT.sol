// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./MockPendleSY.sol";

/**
 * @title MockPendleYT
 * @notice Mock Pendle YT (Yield Token) for testing
 * @dev Models the parts of PendleYieldToken / InterestManagerYT that PendleYTLock depends on:
 *      interest accrues against balance-over-time through a global index, holders are checkpointed on
 *      every transfer, and `redeemDueInterestAndRewards` is permissionless and pays out in SY.
 * @dev Each instance brings its own SY and yield token so a test can construct one and be done.
 */
contract MockPendleYT is ERC20, ERC20Burnable {
    uint256 private constant ONE = 1e18;

    MockPendleSY public immutable SY_TOKEN;
    MockYieldToken public immutable REWARD_TOKEN;

    /// @notice Global interest index; grows as interest accrues to YT holders
    uint256 public interestIndex = ONE;
    mapping(address => uint256) public userIndexOf;
    mapping(address => uint256) public userAccruedOf;

    /// @notice Test hook: force `redeemDueInterestAndRewards` to revert, simulating a Pendle outage
    bool public failRedeem;
    uint256 public expiryTimestamp = type(uint256).max;
    address[] private rewardTokens;

    error YTForcedFailure();

    constructor() ERC20("Mock Pendle YT", "mYT") {
        REWARD_TOKEN = new MockYieldToken("Mock Yield Token", "mYLD");
        SY_TOKEN = new MockPendleSY(address(REWARD_TOKEN));
    }

    /**
     * @notice Mint tokens to any address (for testing)
     * @param to Recipient address
     * @param amount Amount to mint
     */
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    /* ------------- PENDLE VIEWS ------------- */

    /// @notice Test hook: report a different SY, as a Pendle-side migration would
    address private syOverride;

    function setSyOverride(address syOverride_) external {
        syOverride = syOverride_;
    }

    /**
     * @notice The SY this YT is paired with; interest is denominated in it
     */
    function SY() external view returns (address) {
        return syOverride == address(0) ? address(SY_TOKEN) : syOverride;
    }

    /**
     * @notice Simulates Pendle YT expiry check
     */
    function expiry() external view returns (uint256) {
        return expiryTimestamp;
    }

    function isExpired() external view returns (bool) {
        return block.timestamp >= expiryTimestamp;
    }

    function getRewardTokens() external view returns (address[] memory) {
        return rewardTokens;
    }

    function userInterest(address user) external view returns (uint128 index, uint128 accrued) {
        return (uint128(userIndexOf[user]), uint128(userAccruedOf[user]));
    }

    /**
     * @notice Get contract version
     */
    function version() external pure returns (string memory) {
        return "1.0.0";
    }

    /* ------------- TEST HOOKS ------------- */

    /**
     * @notice Accrue `syAmount` of interest across all YT holders, pro-rata by current balance
     * @dev This is how real YT interest behaves across a window in which balances do not change:
     *      the index grows, and each holder's entitlement is balance x index growth.
     */
    function accrueInterest(uint256 syAmount) external {
        uint256 supply = totalSupply();
        require(supply != 0, "MockPendleYT: no supply");

        interestIndex += (syAmount * ONE) / supply;
        _backPayout(syAmount);
    }

    /**
     * @notice Credit exactly `syAmount` of redeemable interest to `holder`, leaving others untouched
     * @dev `accrueInterest` splits an amount across the whole YT supply, which makes an exact
     *      expectation awkward when test wallets hold undeposited YT. This targets one holder so a
     *      test can say "the vault has earned exactly X", which is the input PendleYTLock reacts to.
     */
    function accrueInterestFor(address holder, uint256 syAmount) external {
        require(balanceOf(holder) != 0, "MockPendleYT: holder has no YT");

        _settle(holder);
        userAccruedOf[holder] += syAmount;
        _backPayout(syAmount);
    }

    /// @dev Back a future payout with real yield token held inside the SY
    function _backPayout(uint256 syAmount) private {
        REWARD_TOKEN.mint(address(this), syAmount);
        REWARD_TOKEN.approve(address(SY_TOKEN), syAmount);
        SY_TOKEN.mintFor(address(this), syAmount);
    }

    function setFailRedeem(bool failRedeem_) external {
        failRedeem = failRedeem_;
    }

    function setExpiry(uint256 expiryTimestamp_) external {
        expiryTimestamp = expiryTimestamp_;
    }

    /* ------------- INTEREST ------------- */

    /**
     * @notice Pushes `user`'s accrued interest (in SY) to `user`
     * @dev Permissionless, exactly like Pendle's: anyone may trigger a payout for any holder.
     */
    function redeemDueInterestAndRewards(
        address user,
        bool redeemInterest,
        bool
    )
        external
        returns (uint256 interestOut, uint256[] memory rewardsOut)
    {
        if (failRedeem) revert YTForcedFailure();

        // Reward streaming is out of scope: both Tori markets have an empty reward token list
        rewardsOut = new uint256[](rewardTokens.length);

        if (redeemInterest) {
            _settle(user);
            interestOut = userAccruedOf[user];
            userAccruedOf[user] = 0;
            if (interestOut != 0) {
                IERC20(address(SY_TOKEN)).transfer(user, interestOut);
            }
        }
    }

    function _settle(address user) private {
        uint256 index = interestIndex;
        uint256 userIndex = userIndexOf[user];
        if (userIndex == index) return;

        // A never-touched holder starts accruing from the current index
        if (userIndex != 0) {
            userAccruedOf[user] += (balanceOf(user) * (index - userIndex)) / ONE;
        }
        userIndexOf[user] = index;
    }

    /// @dev Real Pendle checkpoints both sides of a YT transfer, so interest never follows the token
    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0)) _settle(from);
        if (to != address(0)) _settle(to);
        super._update(from, to, value);
    }
}
