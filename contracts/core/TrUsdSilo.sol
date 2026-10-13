// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "../interfaces/ITrUsdSiloDefinitions.sol";

/**
 * @title TrUsdSilo
 * @notice Simple silo for holding TrUSD assets during cooldown period (non-upgradeable)
 * @dev Deployed directly by StakedTrUSD, no proxy pattern needed
 */
contract TrUsdSilo is ITrUsdSiloDefinitions {
    using SafeERC20 for IERC20;

    address public immutable stakingVault;
    IERC20 public immutable trUSD;

    modifier onlyStakingVault() {
        if (msg.sender != stakingVault) revert OnlyStakingVault();
        _;
    }

    constructor(address _stakingVault, address _trUsd) {
        stakingVault = _stakingVault;
        trUSD = IERC20(_trUsd);
    }

    function withdraw(address to, uint256 amount) external onlyStakingVault {
        trUSD.safeTransfer(to, amount);
    }

    function rescueToken(IERC20 token, address to, uint256 amount) external onlyStakingVault {
        if (address(token) == address(trUSD)) revert InvalidToken();
        token.safeTransfer(to, amount);
    }

    function STAKING_VAULT() external view returns (address) {
        return stakingVault;
    }

    function TRUSD() external view returns (address) {
        return address(trUSD);
    }

    function version() external pure returns (string memory) {
        return "1.0.0";
    }
}
