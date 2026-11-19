// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { TrUSD } from "../../contracts/core/TrUSD.sol";
import { ToriMinting } from "../../contracts/core/ToriMinting.sol";
import { HalmosBase } from "./HalmosBase.sol";
import { HalmosToken, HalmosWallet } from "./HalmosMocks.sol";

/// @title ToriMintingHalmos
/// @notice Symbolic properties of signature-based minting and redemption.
/// @dev Bounds: symbolic orders are priced at par (`_par`, any USDC amount below 2^64 units); a route
///      has at most 3 legs; the custodian set holds 2 addresses; dynamic
///      calldata in arbitrary-call properties uses halmos' default lengths (arrays 0/1/2, bytes and
///      strings 0/65/1024). Signatures: halmos models ecrecover as an uninterpreted function, so
///      binding is proven as (a) execution requires the sender's approval of exactly hashOrder(order)
///      and (b) hashOrder is injective over every order field and the chain id. Together they reduce
///      replay or field tampering to forging a signature.
contract ToriMintingHalmos is HalmosBase {
    TrUSD internal trUSD;
    ToriMinting internal minting;
    HalmosToken internal usdc;
    HalmosWallet internal wallet;

    address internal admin = address(0xA11CE);
    address internal timelock = address(0x71E10C);
    address internal op = address(0x0E0E);
    address internal gatekeeper = address(0x6A7E);
    address internal collateralManager = address(0xC0C0);
    address internal whitelister = address(0x5157);
    address internal custodian1 = address(0xC1);
    address internal custodian2 = address(0xC2);

    uint128 internal constant MAX_MINT = 1_000_000e18;
    uint128 internal constant MAX_REDEEM = 1_000_000e18;
    uint128 internal constant GLOBAL_MINT = 2_000_000e18;
    uint128 internal constant GLOBAL_REDEEM = 2_000_000e18;

    function setUp() public {
        TrUSD tImpl = new TrUSD();
        trUSD = TrUSD(address(new ERC1967Proxy(address(tImpl), abi.encodeCall(TrUSD.initialize, (admin)))));
        vm.prank(admin);
        trUSD.initializeTimelockAdmin(timelock);

        usdc = new HalmosToken("USDC", 6);
        address[] memory tokens = new address[](1);
        tokens[0] = address(usdc);
        ToriMinting.TokenConfig[] memory cfgs = new ToriMinting.TokenConfig[](1);
        cfgs[0] = ToriMinting.TokenConfig(ToriMinting.TokenType.STABLE, true, MAX_MINT, MAX_REDEEM);
        minting = new ToriMinting(address(trUSD), tokens, cfgs, GLOBAL_MINT, GLOBAL_REDEEM, admin);

        vm.prank(timelock);
        trUSD.setMinter(address(minting));

        vm.startPrank(admin);
        minting.grantRole(minting.MINTER_ROLE(), op);
        minting.grantRole(minting.REDEEMER_ROLE(), op);
        minting.grantRole(minting.GATEKEEPER_ROLE(), gatekeeper);
        minting.grantRole(minting.COLLATERAL_MANAGER_ROLE(), collateralManager);
        minting.grantRole(minting.WHITELISTER_ROLE(), whitelister);
        minting.initializeTimelockAdmin(timelock);
        vm.stopPrank();

        vm.startPrank(timelock);
        minting.addCustodianAddress(custodian1);
        minting.addCustodianAddress(custodian2);
        minting.setStablesDeltaLimit(50);
        vm.stopPrank();

        wallet = new HalmosWallet();
        vm.prank(whitelister);
        minting.addToWhitelist(address(wallet));
        wallet.approveToken(usdc, address(minting), type(uint256).max);
        wallet.approveToken(trUSD, address(minting), type(uint256).max);
        usdc.mint(address(wallet), type(uint128).max);
    }

    /* ---------------- helpers ---------------- */

    function _order(
        ToriMinting.OrderType t,
        address sender,
        address recipient,
        uint128 collateral,
        uint128 trusd,
        uint256 nonce
    )
        internal
        view
        returns (ToriMinting.Order memory o)
    {
        o = ToriMinting.Order({
            order_type: t,
            sender: sender,
            recipient: recipient,
            collateral_asset: address(usdc),
            collateral_amount: collateral,
            trusd_amount: trusd,
            expiry: uint128(block.timestamp + 1 days),
            nonce: nonce,
            order_id: "id"
        });
    }

    /// @dev trUSD amount at par for `c` USDC (6 decimals). Symbolic orders are priced at par: the price
    ///      band `difference * 10_000 / trusdAmount` is then exactly zero instead of a symbolic
    ///      division, which keeps proofs and counterexample search tractable. Caps, nonces, signatures,
    ///      routing and recipients do not depend on the price.
    function _par(uint64 c) internal pure returns (uint128) {
        return uint128(c) * 1e12;
    }

    function _sig1271() internal pure returns (ToriMinting.Signature memory) {
        return ToriMinting.Signature(ToriMinting.SignatureType.EIP1271, "");
    }

    function _route1() internal view returns (ToriMinting.Route memory r) {
        r.addresses = new address[](1);
        r.ratios = new uint128[](1);
        r.addresses[0] = custodian1;
        r.ratios[0] = 10_000;
    }

    function _tryMint(
        ToriMinting.Order memory o,
        ToriMinting.Signature memory s,
        ToriMinting.Route memory r
    )
        internal
        returns (bool ok)
    {
        vm.prank(op);
        (ok,) = address(minting).call(abi.encodeCall(ToriMinting.mint, (o, s, r)));
    }

    function _tryRedeem(ToriMinting.Order memory o, ToriMinting.Signature memory s) internal returns (bool ok) {
        vm.prank(op);
        (ok,) = address(minting).call(abi.encodeCall(ToriMinting.redeem, (o, s)));
    }

    function _minted() internal view returns (uint128 global, uint128 asset) {
        (global,) = minting.totalPerBlock(block.number);
        (asset,) = minting.totalPerBlockPerAsset(block.number, address(usdc));
    }

    function _redeemed() internal view returns (uint128 global, uint128 asset) {
        (, global) = minting.totalPerBlock(block.number);
        (, asset) = minting.totalPerBlockPerAsset(block.number, address(usdc));
    }

    /* ---------------- caps ---------------- */

    /// @notice Two mints in one block can never take the per-block totals above the global or the
    ///         per-asset cap, whatever the caps are set to beforehand.
    function check_mint_capsNeverExceeded(uint128 g, uint128 m, uint64 c1, uint64 c2) public {
        wallet.setApproveAll(true);
        vm.startPrank(admin);
        minting.setGlobalLimits(g, GLOBAL_REDEEM);
        minting.setMaxMintPerBlock(m, address(usdc));
        vm.stopPrank();

        ToriMinting.Order memory o1 =
            _order(ToriMinting.OrderType.MINT, address(wallet), address(wallet), c1, _par(c1), 1);
        ToriMinting.Order memory o2 =
            _order(ToriMinting.OrderType.MINT, address(wallet), address(wallet), c2, _par(c2), 2);
        _tryMint(o1, _sig1271(), _route1());
        _tryMint(o2, _sig1271(), _route1());

        (uint128 global, uint128 asset) = _minted();
        assert(global <= g);
        assert(asset <= m);
        assert(global == asset);
    }

    /// @notice Two redeems in one block can never take the per-block totals above either cap.
    function check_redeem_capsNeverExceeded(uint128 g, uint128 m, uint64 c1, uint64 c2) public {
        wallet.setApproveAll(true);
        vm.startPrank(admin);
        minting.setGlobalLimits(GLOBAL_MINT, g);
        minting.setMaxRedeemPerBlock(m, address(usdc));
        vm.stopPrank();
        // Give the wallet trUSD to burn and the contract collateral to pay out.
        vm.prank(address(minting));
        trUSD.mint(address(wallet), type(uint128).max);
        usdc.mint(address(minting), type(uint128).max);

        ToriMinting.Order memory o1 =
            _order(ToriMinting.OrderType.REDEEM, address(wallet), address(wallet), c1, _par(c1), 1);
        ToriMinting.Order memory o2 =
            _order(ToriMinting.OrderType.REDEEM, address(wallet), address(wallet), c2, _par(c2), 2);
        _tryRedeem(o1, _sig1271());
        _tryRedeem(o2, _sig1271());

        (uint128 global, uint128 asset) = _redeemed();
        assert(global <= g);
        assert(asset <= m);
    }

    /// @notice After the gatekeeper's disableMintRedeem, no mint or redeem can succeed.
    function check_disableMintRedeem_blocksEverything(uint64 c, uint256 nonce, bool isRedeem) public {
        wallet.setApproveAll(true);
        vm.prank(gatekeeper);
        minting.disableMintRedeem();
        vm.prank(address(minting));
        trUSD.mint(address(wallet), type(uint128).max);
        usdc.mint(address(minting), type(uint128).max);

        bool ok;
        if (isRedeem) {
            ok = _tryRedeem(
                _order(ToriMinting.OrderType.REDEEM, address(wallet), address(wallet), c, _par(c), nonce), _sig1271()
            );
        } else {
            ok = _tryMint(
                _order(ToriMinting.OrderType.MINT, address(wallet), address(wallet), c, _par(c), nonce),
                _sig1271(),
                _route1()
            );
        }
        assert(!ok);
    }

    /// @notice While paused, no mint or redeem can succeed.
    function check_paused_blocksEverything(uint64 c, uint256 nonce, bool isRedeem) public {
        wallet.setApproveAll(true);
        vm.prank(admin);
        minting.pause();
        vm.prank(address(minting));
        trUSD.mint(address(wallet), type(uint128).max);
        usdc.mint(address(minting), type(uint128).max);

        bool ok = isRedeem
            ? _tryRedeem(
                _order(ToriMinting.OrderType.REDEEM, address(wallet), address(wallet), c, _par(c), nonce), _sig1271()
            )
            : _tryMint(
                _order(ToriMinting.OrderType.MINT, address(wallet), address(wallet), c, _par(c), nonce),
                _sig1271(),
                _route1()
            );
        assert(!ok);
    }

    /* ---------------- whitelist, signatures, replay ---------------- */

    /// @notice A sender that is not whitelisted can never mint or redeem, even with a valid signature.
    function check_notWhitelisted_cannotTrade(uint64 c, uint256 nonce, bool isRedeem) public {
        wallet.setApproveAll(true);
        vm.prank(whitelister);
        minting.removeFromWhitelist(address(wallet));
        vm.prank(address(minting));
        trUSD.mint(address(wallet), type(uint128).max);
        usdc.mint(address(minting), type(uint128).max);

        bool ok = isRedeem
            ? _tryRedeem(
                _order(ToriMinting.OrderType.REDEEM, address(wallet), address(wallet), c, _par(c), nonce), _sig1271()
            )
            : _tryMint(
                _order(ToriMinting.OrderType.MINT, address(wallet), address(wallet), c, _par(c), nonce),
                _sig1271(),
                _route1()
            );
        assert(!ok);
    }

    /// @notice An EIP-1271 sender's order executes only if the wallet approved exactly hashOrder(order).
    function check_mint_eip1271_requiresApprovalOfExactDigest(
        uint64 c,
        uint256 nonce,
        address recipient,
        bytes32 approvedDigest
    )
        public
    {
        wallet.approveDigest(approvedDigest);
        if (recipient != address(wallet)) {
            wallet.call(address(minting), abi.encodeCall(ToriMinting.setApprovedRecipient, (recipient, true)));
        }
        ToriMinting.Order memory o = _order(ToriMinting.OrderType.MINT, address(wallet), recipient, c, _par(c), nonce);
        bool ok = _tryMint(o, _sig1271(), _route1());
        if (ok) assert(minting.hashOrder(o) == approvedDigest);
    }

    /// @notice An EOA order executes only if ecrecover over exactly hashOrder(order) yields the sender,
    ///         and never for sender == address(0).
    function check_mint_eip712_requiresSenderSignatureOverDigest(
        address sender,
        uint64 c,
        uint256 nonce,
        bytes32 r,
        bytes32 s,
        uint8 v
    )
        public
    {
        // Setup must not revert for any sender, or that sender's paths would be dropped (address(0)
        // cannot be whitelisted, minted to or approve, and is exactly a case the property covers).
        if (sender != address(0)) {
            vm.prank(whitelister);
            minting.addToWhitelist(sender);
            usdc.mint(sender, type(uint128).max);
            vm.prank(sender);
            usdc.approve(address(minting), type(uint256).max);
        }

        ToriMinting.Order memory o = _order(ToriMinting.OrderType.MINT, sender, sender, c, _par(c), nonce);
        ToriMinting.Signature memory sig =
            ToriMinting.Signature(ToriMinting.SignatureType.EIP712, abi.encodePacked(r, s, v));
        bool ok = _tryMint(o, sig, _route1());
        if (ok) {
            assert(sender != address(0));
            assert(ecrecover(minting.hashOrder(o), v, r, s) == sender);
        }
    }

    /// @notice hashOrder is injective: two orders differing in any field have different digests, so a
    ///         signature for one can never authorize another.
    function check_hashOrder_bindsEveryField(
        ToriMinting.Order memory a,
        uint8 field,
        uint256 delta,
        address altAddr
    )
        public
        view
    {
        a.order_type = ToriMinting.OrderType(uint8(a.order_type) % 2);
        ToriMinting.Order memory b = _copy(a);
        if (field == 0) {
            b.order_type =
                a.order_type == ToriMinting.OrderType.MINT ? ToriMinting.OrderType.REDEEM : ToriMinting.OrderType.MINT;
        } else if (field == 1) {
            b.sender = altAddr;
        } else if (field == 2) {
            b.recipient = altAddr;
        } else if (field == 3) {
            b.collateral_asset = altAddr;
        } else if (field == 4) {
            b.collateral_amount = uint128(delta);
        } else if (field == 5) {
            b.trusd_amount = uint128(delta);
        } else if (field == 6) {
            b.expiry = uint128(delta);
        } else if (field == 7) {
            b.nonce = delta;
        } else {
            b.order_id = string(abi.encodePacked(a.order_id, "x"));
        }

        if (keccak256(abi.encode(a)) != keccak256(abi.encode(b))) {
            assert(minting.hashOrder(a) != minting.hashOrder(b));
        }
    }

    /// @notice The digest of an order changes with the chain id, so a signature cannot be replayed on
    ///         another chain.
    /// @dev Both chains are symbolic and differ from the deployment chain, so both digests come from
    ///      the recomputed domain separator. (Against the deployment chain, the cached separator is a
    ///      concrete hash from setUp, and halmos does not constrain a symbolic keccak term to differ
    ///      from a concrete one, which yields spurious counterexamples.) Chain ids are valid EIP-155 /
    ///      EIP-2294 ids: non-zero and at most 4503599627370476.
    function check_hashOrder_bindsChainId(uint64 chainA, uint64 chainB) public {
        uint256 deployChain = block.chainid;
        vm.assume(chainA != chainB && chainA != deployChain && chainB != deployChain);
        vm.assume(chainA != 0 && chainB != 0 && chainA <= 4_503_599_627_370_476 && chainB <= 4_503_599_627_370_476);
        ToriMinting.Order memory o = _order(ToriMinting.OrderType.MINT, address(wallet), address(wallet), 1, 1, 1);
        vm.chainId(chainA);
        bytes32 onA = minting.hashOrder(o);
        vm.chainId(chainB);
        assert(minting.hashOrder(o) != onA);
    }

    /// @notice Once a nonce has executed for a sender, no order of either type with that nonce can
    ///         execute again for that sender.
    function check_nonce_noReplay(uint256 nonce, uint64 c2, bool secondIsRedeem) public {
        wallet.setApproveAll(true);
        vm.prank(address(minting));
        trUSD.mint(address(wallet), type(uint128).max);
        usdc.mint(address(minting), type(uint128).max);

        ToriMinting.Order memory o1 =
            _order(ToriMinting.OrderType.MINT, address(wallet), address(wallet), 1000e6, 1000e18, nonce);
        bool first = _tryMint(o1, _sig1271(), _route1());
        vm.assume(first);

        vm.roll(block.number + 1);
        bool second = secondIsRedeem
            ? _tryRedeem(
                _order(ToriMinting.OrderType.REDEEM, address(wallet), address(wallet), c2, _par(c2), nonce), _sig1271()
            )
            : _tryMint(
                _order(ToriMinting.OrderType.MINT, address(wallet), address(wallet), c2, _par(c2), nonce),
                _sig1271(),
                _route1()
            );
        assert(!second);
    }

    /// @notice Nonce bookkeeping: zero is never valid, and using nonce n invalidates exactly the
    ///         nonces with the same low 128 bits (n itself, never an unrelated nonce).
    function check_nonce_bitmapExact(uint256 n, uint256 m) public {
        vm.assume(n != 0 && m != 0);
        wallet.setApproveAll(true);
        bool first = _tryMint(
            _order(ToriMinting.OrderType.MINT, address(wallet), address(wallet), 1000e6, 1000e18, n),
            _sig1271(),
            _route1()
        );
        vm.assume(first);

        (bool ok,) = address(minting).staticcall(abi.encodeCall(minting.verifyNonce, (address(wallet), m)));
        assert(ok == (uint128(m) != uint128(n)));
        (ok,) = address(minting).staticcall(abi.encodeCall(minting.verifyNonce, (address(wallet), 0)));
        assert(!ok);
    }

    /// @notice trUSD and redeemed collateral only ever go to the sender or a recipient the sender
    ///         approved on-chain.
    function check_recipient_mustBeSenderOrApproved(address recipient, bool approve, bool isRedeem) public {
        vm.assume(recipient != address(wallet) && recipient != address(0));
        wallet.setApproveAll(true);
        if (approve) {
            wallet.call(address(minting), abi.encodeCall(ToriMinting.setApprovedRecipient, (recipient, true)));
        }
        vm.prank(address(minting));
        trUSD.mint(address(wallet), type(uint128).max);
        usdc.mint(address(minting), type(uint128).max);

        bool ok = isRedeem
            ? _tryRedeem(
                _order(ToriMinting.OrderType.REDEEM, address(wallet), recipient, 1000e6, 1000e18, 7), _sig1271()
            )
            : _tryMint(
                _order(ToriMinting.OrderType.MINT, address(wallet), recipient, 1000e6, 1000e18, 7),
                _sig1271(),
                _route1()
            );
        if (ok) assert(minting.isApprovedRecipient(address(wallet), recipient));
    }

    /* ---------------- collateral routing ---------------- */

    /// @dev Route of 1 to 3 legs. The length is fixed per path (if-chain) because halmos needs concrete
    ///      array sizes.
    function _route(
        uint8 n,
        address[3] memory addrs,
        uint128[3] memory ratios
    )
        internal
        pure
        returns (ToriMinting.Route memory r)
    {
        if (n <= 1) n = 1;
        else if (n == 2) n = 2;
        else n = 3;
        r.addresses = new address[](n);
        r.ratios = new uint128[](n);
        for (uint256 i = 0; i < n; i++) {
            r.addresses[i] = addrs[i];
            r.ratios[i] = ratios[i];
        }
    }

    /// @notice A successful mint moves exactly collateral_amount from the sender, and all of it lands
    ///         on registered custodians: nothing is lost to rounding and nothing goes elsewhere.
    /// @dev Bound: route length 1 to 3.
    /// @custom:halmos --loop 3
    function check_mint_collateralOnlyToCustodians(
        uint8 n,
        address[3] memory addrs,
        uint128[3] memory ratios,
        uint64 c
    )
        public
    {
        wallet.setApproveAll(true);
        uint256 senderBefore = usdc.balanceOf(address(wallet));
        uint256 custodiansBefore = usdc.balanceOf(custodian1) + usdc.balanceOf(custodian2);

        bool ok = _tryMint(
            _order(ToriMinting.OrderType.MINT, address(wallet), address(wallet), c, _par(c), 1),
            _sig1271(),
            _route(n, addrs, ratios)
        );
        if (ok) {
            assert(senderBefore - usdc.balanceOf(address(wallet)) == c);
            assert(usdc.balanceOf(custodian1) + usdc.balanceOf(custodian2) - custodiansBefore == c);
        }
    }

    /// @notice transferToCustody moves exactly `amount` out of the contract and only to custodians.
    /// @dev Bound: route length 1 to 3, ratios fully symbolic; the amount comes from the grid 1, 9_999,
    ///      10_001 and 1e24 + 7 (dust below one basis point, just above, and a large odd amount). With
    ///      the amount symbolic too, `amount * ratio / 10_000` per leg is a two-symbol multiply and
    ///      divide that does not close in budget.
    /// @custom:halmos --loop 3
    function check_transferToCustody_onlyToCustodians(
        uint8 n,
        address[3] memory addrs,
        uint128[3] memory ratios,
        uint8 a
    )
        public
    {
        vm.assume(a < 4);
        uint256 amount = a == 0 ? 1 : a == 1 ? 9999 : a == 2 ? 10_001 : 1e24 + 7;
        usdc.mint(address(minting), type(uint128).max);
        uint256 contractBefore = usdc.balanceOf(address(minting));
        uint256 custodiansBefore = usdc.balanceOf(custodian1) + usdc.balanceOf(custodian2);

        vm.prank(collateralManager);
        (bool ok,) = address(minting)
            .call(abi.encodeCall(ToriMinting.transferToCustody, (address(usdc), amount, _route(n, addrs, ratios))));
        if (ok) {
            assert(contractBefore - usdc.balanceOf(address(minting)) == amount);
            assert(usdc.balanceOf(custodian1) + usdc.balanceOf(custodian2) - custodiansBefore == amount);
        }
    }

    /* ---------------- access control ---------------- */

    /// @notice Only MINTER_ROLE can make ToriMinting mint trUSD, by any call.
    function check_trUSDSupply_onlyMinterRole(address caller) public {
        vm.assume(caller != op);
        wallet.setApproveAll(true);
        uint256 supply = trUSD.totalSupply();
        _arbitraryCall(address(minting), "ToriMinting", caller);
        assert(trUSD.totalSupply() == supply);
    }

    /// @notice Only the timelock can add a custodian or (re)activate a collateral token, by any call.
    /// @dev Bound: the MINTER/REDEEMER operator is excluded as caller. Its mint and redeem paths carry the
    ///      price-band check `difference * 10_000 / trusdAmount` over symbolic amounts, a nonlinear query
    ///      the solver does not close in budget. Neither function writes the custodian set, the token
    ///      config or stablesDeltaLimit (they only write the per-block totals and the nonce bitmap).
    function check_custodiansAndTokens_onlyTimelockAdds(address caller, address token) public {
        vm.assume(caller != timelock && caller != op);
        uint256 custodians = minting.getCustodianAddresses().length;
        bool active = minting.isSupportedAsset(token);
        uint128 delta = minting.stablesDeltaLimit();

        _arbitraryCall(address(minting), "ToriMinting", caller);

        assert(minting.getCustodianAddresses().length <= custodians);
        if (!active) assert(!minting.isSupportedAsset(token));
        assert(minting.stablesDeltaLimit() == delta);
    }

    /// @notice A caller with no role cannot change any role, cap, whitelist entry, custodian or pause
    ///         state, by any call.
    /// @dev halmos gives each branch-feasibility query 1 ms by default and, when one runs out, follows
    ///      both sides. On a slow CI runner that multiplied the paths here (151 locally, up to 1703 on a
    ///      hosted runner) until an assertion query hit its own timeout. A longer branching budget keeps
    ///      the path count the same on every machine.
    /// @custom:halmos --solver-timeout-branching 100ms
    function check_privilegedState_onlyRoleHolders(address caller, address who) public {
        vm.assume(
            caller != admin && caller != timelock && caller != gatekeeper && caller != whitelister
                && caller != collateralManager && caller != op
        );
        uint256 rolesBefore = _roleMask(who);
        bool wl = minting.whitelisted(who);
        uint128 gm = minting.globalMaxMintPerBlock();
        uint128 gr = minting.globalMaxRedeemPerBlock();
        (,, uint128 mm, uint128 mr) = minting.tokenConfig(address(usdc));
        uint256 custodians = minting.getCustodianAddresses().length;
        bool paused = minting.paused();

        _arbitraryCall(address(minting), "ToriMinting", caller);

        assert(_roleMask(who) == rolesBefore);
        assert(minting.whitelisted(who) == wl);
        assert(minting.globalMaxMintPerBlock() == gm && minting.globalMaxRedeemPerBlock() == gr);
        (,, uint128 mm2, uint128 mr2) = minting.tokenConfig(address(usdc));
        assert(mm2 == mm && mr2 == mr);
        assert(minting.getCustodianAddresses().length == custodians);
        assert(minting.paused() == paused);
    }

    /// @notice The gatekeeper can only remove powers: it can revoke roles and zero the global caps,
    ///         never grant a role or raise a cap.
    function check_gatekeeper_canOnlyRemovePowers(address who) public {
        uint256 rolesBefore = _roleMask(who);
        uint128 gm = minting.globalMaxMintPerBlock();
        uint128 gr = minting.globalMaxRedeemPerBlock();

        _arbitraryCall(address(minting), "ToriMinting", gatekeeper);

        // No bit may appear that was not set before.
        assert(_roleMask(who) & ~rolesBefore == 0);
        assert(minting.globalMaxMintPerBlock() <= gm && minting.globalMaxRedeemPerBlock() <= gr);
    }

    /// @notice The admin can never grant itself or anyone TIMELOCK_ADMIN_ROLE, add a custodian, or
    ///         activate a new collateral token.
    function check_admin_cannotBypassTimelock(address who, address token) public {
        bytes32 tl = minting.TIMELOCK_ADMIN_ROLE();
        bool had = minting.hasRole(tl, who);
        uint256 custodians = minting.getCustodianAddresses().length;
        bool active = minting.isSupportedAsset(token);

        _arbitraryCall(address(minting), "ToriMinting", admin);

        assert(minting.hasRole(tl, who) == had);
        assert(minting.getCustodianAddresses().length <= custodians);
        if (!active) assert(!minting.isSupportedAsset(token));
    }

    /// @dev Bit i set when `who` holds the i-th role of `_roleIds`.
    function _roleMask(address who) internal view returns (uint256 mask) {
        bytes32[7] memory roles = _roleIds();
        for (uint256 i = 0; i < 7; i++) {
            mask |= _bit(minting.hasRole(roles[i], who)) << i;
        }
    }

    function _roleIds() internal view returns (bytes32[7] memory r) {
        r[0] = minting.DEFAULT_ADMIN_ROLE();
        r[1] = minting.MINTER_ROLE();
        r[2] = minting.REDEEMER_ROLE();
        r[3] = minting.GATEKEEPER_ROLE();
        r[4] = minting.COLLATERAL_MANAGER_ROLE();
        r[5] = minting.WHITELISTER_ROLE();
        r[6] = minting.TIMELOCK_ADMIN_ROLE();
    }

    function _copy(ToriMinting.Order memory a) internal pure returns (ToriMinting.Order memory b) {
        b = ToriMinting.Order(
            a.order_type,
            a.sender,
            a.recipient,
            a.collateral_asset,
            a.collateral_amount,
            a.trusd_amount,
            a.expiry,
            a.nonce,
            a.order_id
        );
    }
}
