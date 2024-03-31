// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import { Solarray } from "solarray/Solarray.sol";
import { TargetContract } from "../helpers/MerkleGovernorSetup.sol";
import { MerkleGovernorCountingSimple } from "../../src/extensions/MerkleGovernorCountingSimple.sol";
import { IMerkleGovernor } from "../../src/IMerkleGovernor.sol";

import { MerkleGovernorSetup } from "../helpers/MerkleGovernorSetup.sol";

/**
 *  **Additional Testing Plan**
 *
 *  The Proposal and Voting phases of the lifecycle contain the biggest changes
 *  away from OZ governor and, thus, are the areas that require the most deep
 *  testing.
 * 
 * On the proposal side:
 * - Test `requestProposal()`
 *     - Check restricted proposal works for correct proposer
 *     - Check restricted proposal fails for incorrect proposer
 *     - Check that proposal id is hash of args
 *     - Test that length mismatch on targets, values, calldatas fails
 *     - Check that proposal that has already been requested fails
 *     - Assert against the state of the proposal's `proposer`, `voteSnapshot`,
 *     `voteDuration` and `proposalTimepoint` fields being as expected.
 *     - Check that `ProposalRequested` event is emitted with correct args
 *     - Test that `state()` returns `ProposalState::AwaitingValidation`
 * - Test `validateProposal()`
 *     - Test that address other than `_proposalValidator` calling the function
 *     reverts
 *     - Test that if merkle root is not set, validation reverts
 *     - Test that if proposal is not in `ProposalState::AwaitingValidation`,
 *     validation reverts
 *     - Test that invalid proof does not revert but does emit the
 *     `ProposalCancelled` event.
 *     - Test that valid proof emits the `ProposalValidated` event and `state()`
 *     afterwards is `ProposalState::Pending`
 *
 * On the voting side, in addition to the basic `castVote()` tests below:
 * - Test `castVoteWithReason()`
 *     - Test For, Against, Abstain and assert against expected state
 *     - Check that `VoteCast` was emitted with the correct reason
 * - Test `castVoteWithReasonAndParams()`
 *     - Test For, Against, Abstain and assert against expected state
 *     - Check that `VoteCastWithParams` was emitted with params
 * - Test `castVoteBySig()`
 *     - Test For, Against, Abstain and assert against expected state
 *     - Check that `VoteCast` was emitted
 *     - Check that the invalid signer fails
 *     - Check that malleable signature fails
 *     - Check that the correct signer passes
 * - Test `castVoteWithReasonAndParamsBySig()`
 *     - Test For, Against, Abstain and assert against expected state
 *     - Check that correct event is emitted
 *     - Check that invalid signer fails
 *     - Check that malleable signature fails
 *     - Check that correct signer passes
 * - Test oracle update of the snapshot root
 *    - Check that vote begins once a snapshot root has been updated
 *    - Check that `proposalDeadline()` is when the snapshot root was updated
 *    plus the vote duration
 *
 * A couple (2-3) light tests to sanity check Execution stage functions
 * properly.
 *
 * A couple (2-3) light tests to sanity check manual Cancellation functions
 * properly.
 */
contract MerkleGovernor_BasicVotingTest is MerkleGovernorSetup {
    uint256 proposalId;
    uint256 snapshotBlock = block.number + 100;

    function setUp() public override {
        super.setUp();

        // Create a proposal request
        address[] memory targets = Solarray.addresses(address(target));
        uint256[] memory values = Solarray.uint256s(0);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeCall(TargetContract.execute, ());

        vm.prank(proposer1);
        proposalId = governor.requestProposal(targets, values, calldatas, "");

        _submitRoot(block.number - 1, root, votingToken.totalSupply());
        _executeCallback(proposalId, proposer1VotingPower, proofs[0]);

        vm.startPrank(voter1);
    }

    function testCastVoteFor() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IMerkleGovernor.GovernorUnexpectedProposalState.selector, proposalId, 1, bytes32(uint256(4))
            )
        );
        governor.castVote(proposalId, uint8(MerkleGovernorCountingSimple.VoteType.For), voter1VotingPower, proofs[1]);

        vm.roll(block.number + 150);
        _submitRoot(snapshotBlock, root, votingToken.totalSupply());

        vm.expectRevert(
            abi.encodeWithSelector(IMerkleGovernor.GovernorUnexpectedProposalState.selector, 0, 0, bytes32(uint256(4)))
        );
        governor.castVote(0, uint8(MerkleGovernorCountingSimple.VoteType.For), voter1VotingPower, proofs[1]);

        vm.expectRevert(
            abi.encodeWithSelector(IMerkleGovernor.GovernorInvalidVoterProof.selector, voter1, type(uint256).max)
        );
        governor.castVote(proposalId, uint8(MerkleGovernorCountingSimple.VoteType.For), type(uint256).max, proofs[1]);

        (, uint256 forVotesBefore,) = governor.proposalVotes(proposalId);

        assertEq(governor.hasVoted(proposalId, voter1), false);

        governor.castVote(proposalId, uint8(MerkleGovernorCountingSimple.VoteType.For), voter1VotingPower, proofs[1]);

        (, uint256 forVotesAfter,) = governor.proposalVotes(proposalId);

        assertEq(governor.hasVoted(proposalId, voter1), true);
        assertEq(forVotesAfter, forVotesBefore + voter1VotingPower);

        vm.expectRevert(abi.encodeWithSelector(IMerkleGovernor.GovernorAlreadyCastVote.selector, voter1));
        governor.castVote(proposalId, uint8(MerkleGovernorCountingSimple.VoteType.For), voter1VotingPower, proofs[1]);
    }

    function testCastVoteAbstain() public {
        vm.roll(block.number + 150);
        _submitRoot(snapshotBlock, root, votingToken.totalSupply());

        (,, uint256 abstainVotesBefore) = governor.proposalVotes(proposalId);

        governor.castVote(
            proposalId, uint8(MerkleGovernorCountingSimple.VoteType.Abstain), voter1VotingPower, proofs[1]
        );

        (,, uint256 abstainVotesAfter) = governor.proposalVotes(proposalId);

        assertEq(governor.hasVoted(proposalId, voter1), true);
        assertEq(abstainVotesAfter, abstainVotesBefore + voter1VotingPower);
    }

    function testCastVoteAgainst() public {
        vm.roll(block.number + 150);
        _submitRoot(snapshotBlock, root, votingToken.totalSupply());

        (uint256 againstVotesBefore,,) = governor.proposalVotes(proposalId);

        governor.castVote(
            proposalId, uint8(MerkleGovernorCountingSimple.VoteType.Against), voter1VotingPower, proofs[1]
        );

        (uint256 againstVotesAfter,,) = governor.proposalVotes(proposalId);

        assertEq(governor.hasVoted(proposalId, voter1), true);
        assertEq(againstVotesAfter, againstVotesBefore + voter1VotingPower);
    }
}
