// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { IMerkleGovernor } from "./IMerkleGovernor.sol";

interface ICheckpointOracle {
    function getCheckpoint(uint256 timepoint)
        external
        view
        returns (bytes32 merkleRoot, uint256 totalSupply, uint256 approvalTimepoint);
    function setCheckpoint(uint256 timepoint, bytes32 merkleRoot, uint256 totalSupply) external;
    function useBlockNumber() external view returns (bool);
}
