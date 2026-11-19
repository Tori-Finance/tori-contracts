// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC1271 } from "@openzeppelin/contracts/interfaces/IERC1271.sol";

/// @notice Plain ERC20 with configurable decimals and an open mint, used as collateral.
contract HalmosToken is ERC20 {
    uint8 private immutable _dec;

    constructor(string memory name_, uint8 dec_) ERC20(name_, name_) {
        _dec = dec_;
    }

    function decimals() public view override returns (uint8) {
        return _dec;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @notice EIP-1271 wallet that approves exactly the digests it was told to approve.
/// @dev `approveAll` turns it into a wallet that accepts any digest, which isolates the cap, nonce
///      and routing logic of ToriMinting from signature checking.
contract HalmosWallet is IERC1271 {
    mapping(bytes32 => bool) public approved;
    bool public approveAll;

    function setApproveAll(bool v) external {
        approveAll = v;
    }

    function approveDigest(bytes32 digest) external {
        approved[digest] = true;
    }

    function isValidSignature(bytes32 hash, bytes memory) external view returns (bytes4) {
        return approveAll || approved[hash] ? IERC1271.isValidSignature.selector : bytes4(0xffffffff);
    }

    function call(address target, bytes calldata data) external returns (bytes memory) {
        (bool ok, bytes memory ret) = target.call(data);
        require(ok, "call failed");
        return ret;
    }

    function approveToken(IERC20 token, address spender, uint256 amount) external {
        token.approve(spender, amount);
    }
}
