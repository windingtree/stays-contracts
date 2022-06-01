// SPDX-License-Identifier: GPL-3.0-only

pragma solidity ^0.8.13;

import {Context} from '@openzeppelin/contracts/utils/Context.sol';
import {ECDSA} from '@openzeppelin/contracts/utils/cryptography/ECDSA.sol';
import {EIP712} from '@openzeppelin/contracts/utils/cryptography/draft-EIP712.sol';
import {SignatureChecker} from '@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol';

import {IServiceProviderRegistry, Role} from '@windingtree/videre-contracts/contracts/interfaces/IServiceProviderRegistry.sol';
import {ILineRegistry} from '@windingtree/videre-contracts/contracts/interfaces/ILineRegistry.sol';
import {LibVidere} from '@windingtree/videre-contracts/contracts/libraries/LibVidere.sol';
import {Vat} from '@windingtree/videre-contracts/contracts/treasury/vat.sol';

import {LibStays} from './LibStays.sol';

/**
 * @title Stays Videre Implementation
 * @author mfw78 <mfw78@protonmail.com>
 */
contract Stays is Context, EIP712 {
    // --- Auth
    mapping(address => uint256) public wards;

    function rely(address usr) external auth {
        require(live == 1, 'Stays/not-live');
        wards[usr] = 1;
    }

    function deny(address usr) external auth {
        require(live == 1, 'Stays/not-live');
        wards[usr] = 0;
    }

    modifier auth() {
        require(wards[_msgSender()] == 1, 'Stays/not-authorized');
        _;
    }

    modifier validProvider(bytes32 which) {
        require(lines.can(line, which), 'Stays/provider-not-valid');
        _;
    }

    // --- data
    /// @dev stub id to stub storage
    mapping(bytes32 => LibVidere.StubStorage) public state;
    /// @dev bid id to nonce storage
    mapping(bytes32 => uint256) public nonce;

    /// @dev Videre escrow contract
    Vat public vat;
    /// @dev Service Provider registry
    IServiceProviderRegistry public providers;
    /// @dev Line registry
    ILineRegistry public lines;

    uint256 public live; // Active flag
    bytes32 public immutable line; // The videre line code, eg. "stays"

    // --- init
    constructor(
        Vat _vat,
        IServiceProviderRegistry _providers,
        ILineRegistry _lines,
        bytes32 _line,
        string memory _eip712Name,
        string memory _eip712Version
    ) EIP712(_eip712Name, _eip712Version) {
        vat = _vat;
        providers = _providers;
        lines = _lines;
        line = _line;

        wards[_msgSender()] = 1;
        live = 1;
    }

    // --- admin
    function file(bytes32 what, address data) external auth {
        if (what == 'vat') vat = Vat(data);
        else if (what == 'providers') providers = IServiceProviderRegistry(data);
        else if (what == 'lines') lines = ILineRegistry(data);
    }

    // --- state engine

    /**
     * Execute the deal between service provider and consumer
     *
     * NOTE: This assumes that funds have been joined into the escrow facility already
     *       for `_msgSender()`.
     *
     * TODO #1: Handle EIP712 signatures if dst is different to msg.sender
     * TODO #2: Add support for multiple sigs for EIP712 signing of an approve for collateral joining.
     *
     * @param gem to pay for the deal with
     * @param bid constituting the offer from the service provider to the consumer
     * @param params specific to the line (industry) this offer is in
     * @param options that have been selected from the bid
     * @param sigs with a minimum of 1 sig from the service provider, 2 if doing EIP712 approval
     * @return stubId the stub id and the typed data hash of the stub state
     */
    function deal(
        address gem,
        LibVidere.Bid memory bid,
        bytes memory params,
        LibVidere.BidOptions memory options,
        bytes[] memory sigs
    ) public payable validProvider(bid.which) returns (bytes32 stubId, bytes32) {
        /// TODO: Make sure stays is a valid line

        /// @dev variable scoping used to avoid stack too deep errors
        ///      `stay` only needs to checked for validity, here and isn't
        //       required further on.
        {
            // make sure that the params match the bid.params for hashing
            LibStays.Stay memory stay = LibStays.decodeStay(params);
            require(LibStays.hash(stay) == bid.params, 'Stays/invalid-params');

            // make sure the bidder's signature is valid for the provider
            bytes32 bidHash = LibVidere.hash(bid);
            require(
                providers.can(bid.which, Role.BIDDER, ECDSA.recover(_hashTypedDataV4(bidHash), sigs[0])),
                'Stays/invalid-bidder'
            );

            // make sure not to exceed the limit
            /// @dev Having a bid limit allows for distribution of free stubs on a
            ///      limited basis, or flow control.
            uint256 bidNonce = ++nonce[bidHash];
            require(bidNonce <= bid.limit, 'Stays/limit-exceeded');

            /// @dev check that the bid sent from the service provider hasn't expired
            require(block.timestamp <= bid.expiry, 'Stays/bid-expired');

            /// @dev generates unique identifier for the stub
            /// TODO: Analyse for hash collision risk
            stubId = label(bidHash, bidNonce);
        }

        /// @dev Stub state for hashing
        LibVidere.StubState memory stubState = LibVidere.StubState({
            which: bid.which,
            params: bid.params,
            items: bid.items,
            terms: bid.terms,
            cost: LibVidere.gemCost(gem, bid.cost)
        });

        /// @dev process any optional items
        if (options.items.length > 0) {
            (stubState.items, stubState.cost) = LibVidere.addOptions(stubState.items, options.items, stubState.cost);
        }

        /// @dev process any optional terms
        if (options.terms.length > 0) {
            (stubState.terms, stubState.cost) = LibVidere.addOptions(stubState.terms, options.terms, stubState.cost);
        }

        /// @dev make the payment here
        vat.deal(stubId, _msgSender(), stubState.cost.gem, stubState.cost.wad, lines.cut(line));

        /// @dev Stub storage
        /// @dev Provides hash collision protection
        LibVidere.StubStorage storage stubStorage = state[stubId];
        require(stubStorage.state == bytes32(0), 'Stays/stub-exists');

        stubStorage.provider = bid.which;
        stubStorage.state = LibVidere.hash(stubState);
        stubStorage.step = 1;

        /// @dev store all term links
        for (uint256 i = 0; i < stubState.terms.length; i++) {
            LibVidere.BidTerm memory term = stubState.terms[i];
            stubStorage.terms[term.impl] = term.txPayload;
        }

        return (stubId, stubStorage.state);
    }

    // --- progress to another point in the lifecycle
    function jump(
        uint256 to,
        LibVidere.StubState calldata stub,
        LibStays.Stay calldata stay,
        bytes[] calldata sigs
    ) external payable validProvider(stub.which) returns (bytes32) {}

    // --- finalize the stub
    function done(
        LibVidere.StubState calldata stub,
        LibStays.Stay calldata stay,
        bytes[] calldata sigs
    ) external payable validProvider(stub.which) {}

    // --- helpers
    /// @dev by using _nonce, _msgSender and block.timestamp, one consumer can
    //       make up to the `limit - nonce` deals in one block.
    function label(bytes32 bidHash, uint256 _nonce) internal view returns (bytes32) {
        return keccak256(abi.encode(line, bidHash, _nonce, block.timestamp, _msgSender()));
    }
}
