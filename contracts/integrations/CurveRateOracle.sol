// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

/// @dev The Chainlink aggregator surface RedStone push feeds implement. On Monad the strUSD feed is
///      `RedStone Price Feed for strUSD_FUNDAMENTAL` 0xb81131B6368b3F0a83af09dB4E39Ac23DA96C2Db
///      (8 decimals, ERC1967 proxy): the trUSD value of one strUSD, mirroring the Ethereum vault's
///      `convertToAssets(1e18)`. It answers everything below; `latestTimestamp`, `getAnswer` and
///      `getTimestamp` revert on it, so they are not wrapped.
interface IAggregatorV3 {
    function decimals() external view returns (uint8);
    function description() external view returns (string memory);
    function version() external view returns (uint256);
    function latestAnswer() external view returns (int256);
    function latestRound() external view returns (uint256);
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
    function getRoundData(uint80 roundId)
        external
        view
        returns (uint80, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

/**
 * @title CurveRateOracle
 * @notice The same feed with 18 decimals: every answer is the underlying one converted from the
 *         feed's `decimals()` to 18, and `decimals()` says 18. Everything else passes through.
 *         Built for a Curve stableswap-ng pool's "oracle" asset (asset type 1), whose method is
 *         `latestAnswer()` (0x50d25bcd): the pool static-calls it with no arguments and uses the 32
 *         bytes as an 18-decimal uint256, which a positive int256 is.
 *
 * @dev Why it exists: a bridged strUSD on an L2 has no `convertToAssets` (the ERC4626 asset type
 *      is unavailable), and the RedStone feed is 8-decimal.
 *
 *      The feed's decimals are read on every call, not fixed at deployment, so the answer stays
 *      18-decimal even if the feed behind its proxy ever changes them. No owner, no setter: a
 *      Curve pool stores this address at deployment and can never change it.
 */
contract CurveRateOracle is IAggregatorV3 {
    IAggregatorV3 public immutable feed;

    constructor(IAggregatorV3 feed_) {
        feed = feed_;
    }

    function decimals() external pure returns (uint8) {
        return 18;
    }

    function description() external view returns (string memory) {
        return feed.description();
    }

    function version() external view returns (uint256) {
        return feed.version();
    }

    function latestRound() external view returns (uint256) {
        return feed.latestRound();
    }

    /// @notice The Curve method: the feed's answer with 18 decimals.
    function latestAnswer() external view returns (int256) {
        return _to18(feed.latestAnswer());
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound) =
            feed.latestRoundData();
        return (roundId, _to18(answer), startedAt, updatedAt, answeredInRound);
    }

    function getRoundData(uint80 roundId_) external view returns (uint80, int256, uint256, uint256, uint80) {
        (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound) =
            feed.getRoundData(roundId_);
        return (roundId, _to18(answer), startedAt, updatedAt, answeredInRound);
    }

    function _to18(int256 answer) private view returns (int256) {
        uint8 d = feed.decimals();
        return d <= 18 ? answer * int256(10 ** (18 - d)) : answer / int256(10 ** (d - 18));
    }
}
