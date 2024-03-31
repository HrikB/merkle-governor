// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import { MerkleGovernor } from "../MerkleGovernor.sol";
import { ICheckpointOracle } from "../ICheckpointOracle.sol";
import { MerkleGovernorCountingSimple } from "../extensions/MerkleGovernorCountingSimple.sol";
import { MerkleGovernorSettings } from "../extensions/MerkleGovernorSettings.sol";

contract MerkleGovernorSimple is MerkleGovernorCountingSimple, MerkleGovernorSettings {
    constructor(
        uint48 initialSnapshotDelay,
        uint32 initialVotingPeriod,
        uint256 initialProposalThreshold,
        string memory name_,
        ICheckpointOracle checkpointOracle_,
        address proposalValidator_
    )
        MerkleGovernor(name_, checkpointOracle_, proposalValidator_)
        MerkleGovernorSettings(initialSnapshotDelay, initialVotingPeriod, initialProposalThreshold)
    { }

    function clock() public view virtual override returns (uint48) {
        // Unsafe cast OK
        return uint48(block.number);
    }

    /**
     * @dev Machine-readable description of the clock as specified in EIP-6372.
     */
    // solhint-disable-next-line func-name-mixedcase
    function CLOCK_MODE() public view virtual override returns (string memory) {
        return "mode=blocknumber&from=default";
    }

    function quorum(uint256 timepoint) public view override returns (uint256) {
        (, uint256 totalSupply,) = _checkpointOracle.getCheckpoint(timepoint);

        // 10% of total supply
        return totalSupply / 10;
    }
}
