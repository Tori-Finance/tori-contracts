// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import "@openzeppelin/contracts/governance/TimelockController.sol";

contract ToriTimelock is TimelockController {
    uint256 public constant MIN_DELAY = 1 days;
    uint256 public constant MAX_DELAY = 30 days;

    /// @param minDelay       Seconds between scheduling and execution.
    /// @param timelockAdmin  Keeps PROPOSER_ROLE.
    /// @param canceller      Sole holder of CANCELLER_ROLE.
    /// @param executor       Sole holder of EXECUTOR_ROLE. Pass `timelockAdmin`
    ///                       to keep proposing and executing on one address.
    constructor(uint256 minDelay, address timelockAdmin, address canceller, address executor)
        TimelockController(minDelay, _toArray(timelockAdmin), _toArray(timelockAdmin), address(this))
    {
        require(minDelay >= MIN_DELAY, "Delay too short");
        require(minDelay <= MAX_DELAY, "Delay too long");
        require(timelockAdmin != address(0), "Invalid timelock admin");
        require(canceller != address(0), "Invalid canceller");
        require(executor != address(0), "Invalid executor");

        _revokeRole(CANCELLER_ROLE, timelockAdmin); // remove timelockAdmin's canceller role
        _grantRole(CANCELLER_ROLE, canceller); // grant canceller role to canceller

        if (executor != timelockAdmin) {
            _revokeRole(EXECUTOR_ROLE, timelockAdmin);
            _grantRole(EXECUTOR_ROLE, executor);
        }

        _revokeRole(DEFAULT_ADMIN_ROLE, address(this)); // renounce temp admin
    }

    function _toArray(address addr) private pure returns (address[] memory) {
        address[] memory arr = new address[](1);
        arr[0] = addr;
        return arr;
    }

    function _execute(address target, uint256 value, bytes calldata data) internal override {
        if (target == address(this) && data.length >= 4 && bytes4(data[:4]) == this.updateDelay.selector) {
            uint256 newDelay = abi.decode(data[4:], (uint256));
            require(newDelay >= MIN_DELAY, "Delay too short");
            require(newDelay <= MAX_DELAY, "Delay too long");
        }
        super._execute(target, value, data);
    }

    function getOperationStateString(bytes32 id) external view returns (string memory state) {
        OperationState opState = getOperationState(id);

        if (opState == OperationState.Unset) return "Unset";
        if (opState == OperationState.Waiting) return "Waiting";
        if (opState == OperationState.Ready) return "Ready";
        if (opState == OperationState.Done) return "Done";

        return "Unknown";
    }

    function getTimeRemaining(bytes32 id) external view returns (uint256 remaining) {
        uint256 timestamp = getTimestamp(id);

        if (timestamp == 0 || timestamp == 1) return 0; // Unset or Done
        if (block.timestamp >= timestamp) return 0; // Ready

        return timestamp - block.timestamp;
    }
}
