// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { TimelockController } from "@openzeppelin/contracts/governance/TimelockController.sol";
import { ToriTimelock } from "../../contracts/governance/ToriTimelock.sol";
import { ToriMinting } from "../../contracts/core/ToriMinting.sol";
import { TrUSD } from "../../contracts/core/TrUSD.sol";
import { HalmosBase } from "./HalmosBase.sol";
import { HalmosToken } from "./HalmosMocks.sol";

/// @title ToriTimelockHalmos
/// @notice Symbolic properties of governance: the delay, the role split, and that ToriMinting's
///         timelock-only powers (custodians, collateral tokens) really sit behind the delay.
contract ToriTimelockHalmos is HalmosBase {
    uint256 internal constant MIN_DELAY = 1 days;
    uint256 internal constant MAX_DELAY = 30 days;

    ToriTimelock internal timelock;
    ToriMinting internal minting;
    address internal proposer = address(0x9909);
    address internal canceller = address(0xCA9C);
    address internal executor = address(0xE8EC);
    address internal mintingAdmin = address(0xA11CE);

    bytes32 internal pendingId;

    function setUp() public {
        timelock = new ToriTimelock(MIN_DELAY, proposer, canceller, executor);

        TrUSD tImpl = new TrUSD();
        TrUSD trUSD = TrUSD(address(new ERC1967Proxy(address(tImpl), abi.encodeCall(TrUSD.initialize, (mintingAdmin)))));
        HalmosToken usdc = new HalmosToken("USDC", 6);
        address[] memory tokens = new address[](1);
        tokens[0] = address(usdc);
        ToriMinting.TokenConfig[] memory cfgs = new ToriMinting.TokenConfig[](1);
        cfgs[0] = ToriMinting.TokenConfig(ToriMinting.TokenType.STABLE, true, 1e24, 1e24);
        minting = new ToriMinting(address(trUSD), tokens, cfgs, 1e24, 1e24, mintingAdmin);
        vm.prank(mintingAdmin);
        minting.initializeTimelockAdmin(address(timelock));

        // One operation left pending, so the role properties also cover cancel and execute paths.
        vm.prank(proposer);
        timelock.schedule(
            address(minting), 0, abi.encodeCall(minting.addCustodianAddress, (address(0xC1))), 0, 0, MIN_DELAY
        );
        pendingId = timelock.hashOperation(
            address(minting), 0, abi.encodeCall(minting.addCustodianAddress, (address(0xC1))), 0, 0
        );
    }

    /// @dev Bit i set when `who` holds the i-th role of `_roleIds`.
    function _roleMask(address who) internal view returns (uint256 mask) {
        bytes32[4] memory roles = _roleIds();
        for (uint256 i = 0; i < 4; i++) {
            mask |= _bit(timelock.hasRole(roles[i], who)) << i;
        }
    }

    function _roleIds() internal view returns (bytes32[4] memory r) {
        r[0] = timelock.DEFAULT_ADMIN_ROLE();
        r[1] = timelock.PROPOSER_ROLE();
        r[2] = timelock.EXECUTOR_ROLE();
        r[3] = timelock.CANCELLER_ROLE();
    }

    /// @notice The constructor accepts exactly the delays in [1 day, 30 days].
    function check_constructor_delayBounds(uint256 minDelay) public {
        bool ok;
        try new ToriTimelock(minDelay, proposer, canceller, executor) returns (ToriTimelock) {
            ok = true;
        } catch {
            ok = false;
        }
        assert(ok == (minDelay >= MIN_DELAY && minDelay <= MAX_DELAY));
    }

    /// @notice After construction the role split is exact and nobody, the timelock included, holds
    ///         DEFAULT_ADMIN_ROLE, so the role set can never be changed afterwards.
    function check_constructor_roleSplit(address a, address c, address e, address who) public {
        vm.assume(a != address(0) && c != address(0) && e != address(0));
        ToriTimelock t = new ToriTimelock(MIN_DELAY, a, c, e);

        assert(!t.hasRole(t.DEFAULT_ADMIN_ROLE(), who));
        assert(t.hasRole(t.PROPOSER_ROLE(), who) == (who == a));
        assert(t.hasRole(t.EXECUTOR_ROLE(), who) == (who == e));
        assert(t.hasRole(t.CANCELLER_ROLE(), who) == (who == c));
    }

    /// @notice The role set is final: no call by anyone, the timelock and every role holder included,
    ///         adds or removes a member of any role.
    /// @dev Until ToriTimelock reverted renounceRole this could only be proven in a narrowed form (a
    ///      holder could remove itself, and with no DEFAULT_ADMIN_ROLE the role was gone for good).
    ///      See test/halmos/README.md, finding F-2.
    function check_roles_final(address caller, address who) public {
        uint256 before = _roleMask(who);

        _arbitraryCall(address(timelock), "ToriTimelock", caller);

        assert(_roleMask(who) == before);
    }

    /// @notice Only the proposer can create an operation, only the canceller can remove a pending one,
    ///         and only the executor can complete one.
    /// @dev Run while the pending operation is still waiting: once it is ready, the symbolic `id` lookup
    ///      against the executable operation exceeds the CI budget. Executing a ready operation is
    ///      covered by check_execute_onlyExecutor.
    ///      The timelock itself is not a caller: it can only call itself from inside `execute`, which
    ///      check_updateDelay_staysInBounds and check_selfCall_cannotEscapeBounds cover.
    function check_operationState_onlyRoleHolders(address caller, bytes32 id) public {
        vm.assume(caller != proposer && caller != canceller && caller != executor && caller != address(timelock));
        uint256 tsPending = timelock.getTimestamp(pendingId);
        uint256 tsAny = timelock.getTimestamp(id);
        uint256 delay = timelock.getMinDelay();

        _arbitraryCall(address(timelock), "ToriTimelock", caller);

        assert(timelock.getTimestamp(pendingId) == tsPending);
        assert(timelock.getTimestamp(id) == tsAny);
        assert(timelock.getMinDelay() == delay);
    }

    /// @notice Once an operation is ready, nobody but the executor can execute it.
    function check_execute_onlyExecutor(address caller) public {
        vm.assume(caller != executor);
        vm.warp(block.timestamp + MIN_DELAY);
        vm.prank(caller);
        (bool ok,) = address(timelock)
            .call(
                abi.encodeCall(
                    TimelockController.execute,
                    (address(minting), 0, abi.encodeCall(minting.addCustodianAddress, (address(0xC1))), 0, 0)
                )
            );
        assert(!ok);
        assert(timelock.isOperationPending(pendingId));
    }

    /// @notice schedule rejects any delay below the current minimum.
    function check_schedule_rejectsShortDelay(uint256 delay, bytes32 salt) public {
        vm.assume(delay < timelock.getMinDelay());
        vm.prank(proposer);
        (bool ok,) = address(timelock)
            .call(abi.encodeCall(TimelockController.schedule, (address(minting), 0, "", bytes32(0), salt, delay)));
        assert(!ok);
    }

    /// @notice An operation can never execute earlier than minDelay after it was scheduled.
    function check_execute_notBeforeMinDelay(uint256 delay, uint256 waited, address custodian) public {
        vm.assume(custodian != address(0) && custodian != address(minting) && custodian != address(0xC1));
        vm.assume(delay < 365 days && waited < 365 days);
        bytes memory data = abi.encodeCall(minting.addCustodianAddress, (custodian));
        uint256 t0 = block.timestamp;

        vm.prank(proposer);
        timelock.schedule(address(minting), 0, data, 0, bytes32(uint256(1)), delay);
        vm.warp(t0 + waited);

        vm.prank(executor);
        (bool ok,) = address(timelock)
            .call(abi.encodeCall(TimelockController.execute, (address(minting), 0, data, 0, bytes32(uint256(1)))));

        if (ok) {
            assert(waited >= MIN_DELAY);
            assert(waited >= delay);
        }
    }

    /// @notice A custodian lands on ToriMinting only through a timelock operation that waited out the
    ///         delay: composed with ToriMinting's own TIMELOCK_ADMIN_ROLE gate.
    function check_custodianAddition_onlyAfterDelay(uint256 waited) public {
        vm.assume(waited < 365 days);
        uint256 before = minting.getCustodianAddresses().length;
        vm.warp(block.timestamp + waited);

        vm.prank(executor);
        (bool ok,) = address(timelock)
            .call(
                abi.encodeCall(
                    TimelockController.execute,
                    (address(minting), 0, abi.encodeCall(minting.addCustodianAddress, (address(0xC1))), 0, 0)
                )
            );

        if (minting.getCustodianAddresses().length > before) {
            assert(ok);
            assert(waited >= MIN_DELAY);
        }
    }

    /// @notice Whatever operation governance schedules and executes against the timelock itself,
    ///         the minimum delay stays within [1 day, 30 days].
    function check_updateDelay_staysInBounds(uint256 newDelay, bool useBatch) public {
        bytes memory data = abi.encodeCall(TimelockController.updateDelay, (newDelay));
        bytes32 salt = bytes32(uint256(2));

        vm.prank(proposer);
        if (useBatch) {
            address[] memory targets = new address[](1);
            uint256[] memory values = new uint256[](1);
            bytes[] memory payloads = new bytes[](1);
            targets[0] = address(timelock);
            payloads[0] = data;
            timelock.scheduleBatch(targets, values, payloads, 0, salt, MIN_DELAY);
            vm.warp(block.timestamp + MIN_DELAY);
            vm.prank(executor);
            (bool ok,) = address(timelock)
                .call(abi.encodeCall(TimelockController.executeBatch, (targets, values, payloads, 0, salt)));
            ok;
        } else {
            timelock.schedule(address(timelock), 0, data, 0, salt, MIN_DELAY);
            vm.warp(block.timestamp + MIN_DELAY);
            vm.prank(executor);
            (bool ok,) = address(timelock)
                .call(abi.encodeCall(TimelockController.execute, (address(timelock), 0, data, 0, salt)));
            ok;
        }

        uint256 d = timelock.getMinDelay();
        assert(d >= MIN_DELAY && d <= MAX_DELAY);
    }

    /// @notice Executing any self-targeted call that governance could schedule leaves the delay in
    ///         bounds and the role set untouched.
    function check_selfCall_cannotEscapeBounds(address who) public {
        bytes memory data = svm.createCalldata("ToriTimelock");
        bytes32 salt = bytes32(uint256(3));
        uint256 before = _roleMask(who);

        vm.prank(proposer);
        timelock.schedule(address(timelock), 0, data, 0, salt, MIN_DELAY);
        vm.warp(block.timestamp + MIN_DELAY);
        vm.prank(executor);
        (bool ok,) =
            address(timelock).call(abi.encodeCall(TimelockController.execute, (address(timelock), 0, data, 0, salt)));
        ok;

        uint256 d = timelock.getMinDelay();
        assert(d >= MIN_DELAY && d <= MAX_DELAY);
        assert(_roleMask(who) == before);
    }
}
