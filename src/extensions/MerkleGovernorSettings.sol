// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { MerkleGovernor } from "../MerkleGovernor.sol";

abstract contract MerkleGovernorSettings is MerkleGovernor {
    // amount of token
    uint256 private _proposalThreshold;
    // timepoint: limited to uint48 in core (same as clock() type)
    uint48 private _snapshotDelay;
    // duration: limited to uint32 in core
    uint32 private _votingPeriod;

    event SnapshotDelaySet(uint256 oldSnapshotDelay, uint256 newSnapshotDelay);
    event VotingPeriodSet(uint256 oldVotingPeriod, uint256 newVotingPeriod);
    event ProposalThresholdSet(uint256 oldProposalThreshold, uint256 newProposalThreshold);

    /**
     * @dev Initialize the governance parameters.
     */
    constructor(uint48 initialSnapshotDelay, uint32 initialVotingPeriod, uint256 initialProposalThreshold) {
        _setSnapshotDelay(initialSnapshotDelay);
        _setVotingPeriod(initialVotingPeriod);
        _setProposalThreshold(initialProposalThreshold);
    }

    /**
     * @dev See {IMerkleGovernor-snapshotDelay}.
     */
    function snapshotDelay() public view virtual override returns (uint256) {
        return _snapshotDelay;
    }

    /**
     * @dev See {IMerkleGovernor-votingPeriod}.
     */
    function votingPeriod() public view virtual override returns (uint256) {
        return _votingPeriod;
    }

    /**
     * @dev See {IMerkleGovernor-proposalThreshold}.
     */
    function proposalThreshold() public view virtual override returns (uint256) {
        return _proposalThreshold;
    }

    /**
     * @dev Update the voting delay. This operation can only be performed through a governance proposal.
     *
     * Emits a {SnapshotDelaySet} event.
     */
    function setSnapshotDelay(uint48 newSnapshotDelay) public virtual onlyGovernance {
        _setSnapshotDelay(newSnapshotDelay);
    }

    /**
     * @dev Update the voting period. This operation can only be performed through a governance proposal.
     *
     * Emits a {VotingPeriodSet} event.
     */
    function setVotingPeriod(uint32 newVotingPeriod) public virtual onlyGovernance {
        _setVotingPeriod(newVotingPeriod);
    }

    /**
     * @dev Update the proposal threshold. This operation can only be performed through a governance proposal.
     *
     * Emits a {ProposalThresholdSet} event.
     */
    function setProposalThreshold(uint256 newProposalThreshold) public virtual onlyGovernance {
        _setProposalThreshold(newProposalThreshold);
    }

    /**
     * @dev Internal setter for the voting delay.
     *
     * Emits a {SnapshotDelaySet} event.
     */
    function _setSnapshotDelay(uint48 newSnapshotDelay) internal virtual {
        emit SnapshotDelaySet(_snapshotDelay, newSnapshotDelay);
        _snapshotDelay = newSnapshotDelay;
    }

    /**
     * @dev Internal setter for the voting period.
     *
     * Emits a {VotingPeriodSet} event.
     */
    function _setVotingPeriod(uint32 newVotingPeriod) internal virtual {
        if (newVotingPeriod == 0) {
            revert GovernorInvalidVotingPeriod(0);
        }
        emit VotingPeriodSet(_votingPeriod, newVotingPeriod);
        _votingPeriod = newVotingPeriod;
    }

    /**
     * @dev Internal setter for the proposal threshold.
     *
     * Emits a {ProposalThresholdSet} event.
     */
    function _setProposalThreshold(uint256 newProposalThreshold) internal virtual {
        emit ProposalThresholdSet(_proposalThreshold, newProposalThreshold);
        _proposalThreshold = newProposalThreshold;
    }
}
