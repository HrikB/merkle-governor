// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import { MockCheckpointOracle } from "./MockCheckpointOracle.sol";
import { MerkleGovernorSimple } from "../../src/examples/MerkleGovernorSimple.sol";
import { ERC20Mintable } from "./ERC20Mintable.sol";

import { Solarray } from "solarray/Solarray.sol";

import { Test } from "forge-std/Test.sol";
import { VmSafe as Vm } from "forge-std/Vm.sol";

import { MerkleProof } from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";

contract TargetContract {
    bool public executed;
    address public sender;

    function execute() public {
        executed = true;
        sender = msg.sender;
    }
}

/**
 * Currently, the setup contract is kept simple by hardcoding the proofs. To
 * support more complex forms of testing, the setup contract would ideally be
 * extended to calculate proofs and roots dynamically so that scenarios with
 * changing user balances can be tested.
 *
 * This extension would also enable to testing of a dynamically changing quorum
 * based on total supply.
 */
contract MerkleGovernorSetup is Test {
    modifier prankAgnostic() {
        (Vm.CallerMode mode, address msgSender,) = vm.readCallers();
        if (mode == Vm.CallerMode.Prank || mode == Vm.CallerMode.RecurrentPrank) {
            vm.stopPrank();
        }

        _;

        if (mode == Vm.CallerMode.Prank) {
            vm.prank(msgSender);
        } else if (mode == Vm.CallerMode.RecurrentPrank) {
            vm.startPrank(msgSender);
        }
    }

    MockCheckpointOracle public checkpointOracle;
    MerkleGovernorSimple governor;

    address proposalValidator = makeAddr("proposalValidator");

    // Technically, can be tested without a token
    ERC20Mintable votingToken;

    address proposer1 = makeAddr("proposer1");
    address voter1 = makeAddr("voter1");

    uint256 proposer1VotingPower = 1e18;
    uint256 voter1VotingPower = 0.2e18;

    address[] tokenHolders = Solarray.addresses(proposer1, voter1);
    uint256[] votingPowers = Solarray.uint256s(proposer1VotingPower, voter1VotingPower);

    // Hash of address and voting power concatenated
    bytes32[] leaves = Solarray.bytes32s(
        0x9b5224673e60b87de3ce47c2b1f4c369e715c5b7b93257ad2df3976c5e387079,
        0x2e86425c1edcc58c5af201c6f439d0c332d378dec173979f09320e4f19304471
    );
    bytes32 root = 0x6e4eeee85e9af4eff622adb6bcf0a4a5a23d1beb4a823ee026b097c1cd3ff56e;
    bytes32[][] proofs;

    TargetContract target;

    function setUp() public virtual {
        target = new TargetContract();
        votingToken = new ERC20Mintable("VotingToken", "VTK");
        checkpointOracle = new MockCheckpointOracle({ _useBlockNumber: true });

        // Governor does not need any knowledge of how the voting power is
        // calculated, it blindly trust the oracle.
        governor = new MerkleGovernorSimple({
            initialSnapshotDelay: 100, // 100 blocks
            initialVotingPeriod: 2000, // 2000 blocks
            initialProposalThreshold: 2e18, // 2 tokens
            name_: "MerkleGovernorSimple",
            checkpointOracle_: checkpointOracle,
            proposalValidator_: proposalValidator
        });

        for (uint256 i = 0; i < tokenHolders.length; i++) {
            votingToken.mint(tokenHolders[i], votingPowers[i]);
        }

        proofs = new bytes32[][](leaves.length);
        // Proof for voter 1
        proofs[0] = Solarray.bytes32s(0x2e86425c1edcc58c5af201c6f439d0c332d378dec173979f09320e4f19304471);
        // Proof for voter 2
        proofs[1] = Solarray.bytes32s(0x9b5224673e60b87de3ce47c2b1f4c369e715c5b7b93257ad2df3976c5e387079);
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                           HELPERS                          */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    function _submitRoot(uint256 timepoint, bytes32 _root, uint256 totalSupply) internal {
        checkpointOracle.setCheckpoint(timepoint, _root, totalSupply);
    }

    function _executeCallback(
        uint256 proposalId,
        uint256 proposerVotingPower,
        bytes32[] memory proof
    )
        internal
        prankAgnostic
    {
        vm.prank(proposalValidator);
        governor.validateProposal(proposalId, proposerVotingPower, proof);
    }

    function _calculateMalleableSignature(
        uint8 v,
        bytes32 r,
        bytes32 s
    )
        internal
        pure
        returns (uint8, bytes32, bytes32)
    {
        // Ensure v is within the valid range (27 or 28)
        require(v == 27 || v == 28, "Invalid v value");

        // Calculate the other s value by negating modulo the curve order n
        uint256 n = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;
        uint256 otherS = n - uint256(s);

        // Calculate the other v value
        uint8 otherV = 55 - v;

        return (otherV, r, bytes32(otherS));
    }
}
