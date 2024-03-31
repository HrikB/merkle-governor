// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import { ICheckpointOracle } from "../../src/ICheckpointOracle.sol";
import { IMerkleGovernor } from "../../src/IMerkleGovernor.sol";

contract MockCheckpointOracle is ICheckpointOracle {
    struct Checkpoint {
        bytes32 merkleRoot;
        uint256 totalSupply;
        uint256 approvalTimepoint;
    }

    bool public immutable useBlockNumber;

    constructor(bool _useBlockNumber) {
        useBlockNumber = _useBlockNumber;
    }

    mapping(uint256 timepoint => Checkpoint) private checkpoints;

    function getCheckpoint(uint256 timepoint)
        external
        view
        override
        returns (bytes32 merkleRoot, uint256 totalSupply, uint256 approvalTimepoint)
    {
        Checkpoint storage checkpoint = checkpoints[timepoint];
        return (checkpoint.merkleRoot, checkpoint.totalSupply, checkpoint.approvalTimepoint);
    }

    function setCheckpoint(uint256 timepoint, bytes32 merkleRoot, uint256 totalSupply) external override {
        uint256 clock = useBlockNumber ? block.number : block.timestamp;
        checkpoints[timepoint] = Checkpoint(merkleRoot, totalSupply, clock);
    }
}
