// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

interface ITrUsdSiloDefinitions {
    /// @notice Only the staking vault can perform an action
    error OnlyStakingVault();
    /// @notice Cannot rescue the native silo token
    error InvalidToken();
}
