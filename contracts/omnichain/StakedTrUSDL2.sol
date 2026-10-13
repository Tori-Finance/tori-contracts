// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {
    FactoryBurnMintERC20
} from "@chainlink/contracts-ccip/contracts/tokenAdminRegistry/TokenPoolFactory/FactoryBurnMintERC20.sol";

/// @title StakedTrUSDL2
/// @notice Destination-chain strUSD: Chainlink's `FactoryBurnMintERC20` plus a
///         blacklist that blocks every transfer, mint and burn involving a
///         blacklisted address.
///
///         Under CCIP's CCT model the off-ramp calls `releaseOrMint` on the
///         pool and `mint` here in a single destination-chain transaction, so
///         a revert in the hook below aborts the inbound bridge atomically.
///         The owner sets the `blackLister`; the `blackLister` maintains the
///         entries.
contract StakedTrUSDL2 is FactoryBurnMintERC20 {
    /// @notice The only address allowed to add and remove blacklist entries.
    address public blackLister;

    mapping(address => bool) public blackList;

    event BlackListerSet(address indexed previousBlackLister, address indexed newBlackLister);
    event AddedToBlackList(address indexed account);
    event RemovedFromBlackList(address indexed account);
    event RedistributeFunds(address indexed from, uint256 amount);

    error BlackListed(address account);
    error NotBlackListed();
    error OnlyBlackLister(address sender);

    modifier onlyBlackLister() {
        if (msg.sender != blackLister) revert OnlyBlackLister(msg.sender);
        _;
    }

    constructor(
        string memory name,
        string memory symbol,
        uint8 decimals_,
        uint256 maxSupply_,
        uint256 preMint,
        address newOwner
    )
        FactoryBurnMintERC20(name, symbol, decimals_, maxSupply_, preMint, newOwner)
    {
        if (newOwner != msg.sender) {
            transferOwnership(newOwner);
        }
    }

    /// @inheritdoc FactoryBurnMintERC20
    function typeAndVersion() external pure override returns (string memory) {
        return "StakedTrUSDL2 1.0.0";
    }

    // ─── blacklister wiring ─────────────────────────────────────────────────

    /// @notice Sets the blacklist manager. Passing address(0) leaves the
    ///         existing entries in force but freezes the set.
    function setBlackLister(address newBlackLister) external onlyOwner {
        emit BlackListerSet(blackLister, newBlackLister);
        blackLister = newBlackLister;
    }

    // ─── blacklist management ───────────────────────────────────────────────

    function addToBlackList(address account) external onlyBlackLister {
        blackList[account] = true;
        emit AddedToBlackList(account);
    }

    function removeFromBlackList(address account) external onlyBlackLister {
        blackList[account] = false;
        emit RemovedFromBlackList(account);
    }

    function addToBlackListBatch(address[] calldata accounts) external onlyBlackLister {
        for (uint256 i = 0; i < accounts.length; ++i) {
            blackList[accounts[i]] = true;
            emit AddedToBlackList(accounts[i]);
        }
    }

    function removeFromBlackListBatch(address[] calldata accounts) external onlyBlackLister {
        for (uint256 i = 0; i < accounts.length; ++i) {
            blackList[accounts[i]] = false;
            emit RemovedFromBlackList(accounts[i]);
        }
    }

    /// @notice Pulls funds out of a blacklisted address to the contract owner.
    ///         The address remains blacklisted before and after; the entry
    ///         is lifted only for the duration of the internal transfer.
    function redistributeBlackListedFunds(address from, uint256 amount) external onlyOwner {
        if (!blackList[from]) revert NotBlackListed();

        blackList[from] = false;
        _transfer(from, msg.sender, amount);
        blackList[from] = true;

        emit RedistributeFunds(from, amount);
    }

    // ─── blacklist enforcement ──────────────────────────────────────────────

    /// @dev Reverts on any movement (transfer, mint, burn) involving a
    ///      blacklisted address. Hooks into every state-changing path via
    ///      OZ 4.x's `_beforeTokenTransfer`.
    function _beforeTokenTransfer(address from, address to, uint256 amount) internal virtual override {
        if (blackList[from]) revert BlackListed(from);
        if (blackList[to]) revert BlackListed(to);
        super._beforeTokenTransfer(from, to, amount);
    }
}
