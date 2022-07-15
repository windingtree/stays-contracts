/* eslint-disable camelcase */
import { TypedDataField } from '@ethersproject/abstract-signer'
import { ethers, getNamedAccounts, deployments, getUnnamedAccounts } from 'hardhat'
import { utils } from 'ethers'

import { expect } from './chai-setup'
import { setupUser, setupUsers } from './utils'

import {
  GemJoin,
  LineRegistry,
  ServiceProviderRegistry,
  ServiceProviderRegistry__factory,
  TimestampRegistry,
  Vat
} from '../typechain-videre'

import { MockERC20, Stays } from '../typechain'
import { bidask } from '@windingtree/videre-sdk/dist/cjs/eip712'

const WHITELIST_ROLE = utils.keccak256(utils.toUtf8Bytes('videre.roles.whitelist'))
const API_ROLE = 1
const BIDDER_ROLE = 2
const MANAGER_ROLE = 3
const STAFF_ROLE = 4

const LINE = utils.formatBytes32String('stays')

const SP_SALT = utils.arrayify(utils.formatBytes32String('SALT'))

const setup = deployments.createFixture(async () => {
  await deployments.fixture(['Stays', 'Vat', 'TimestampRegistry', 'ServiceProviderRegistry', 'LineRegistry', 'GemJoin'])
  const { deployer, alice, bob, carol, api, bidder, manager, staff } = await getNamedAccounts()
  const contracts = {
    erc20: (await ethers.getContract('MockERC20')) as MockERC20,
    vat: (await ethers.getContract('Vat')) as Vat,
    join: (await ethers.getContract('GemJoin')) as GemJoin,
    spRegistry: (await ethers.getContract('ServiceProviderRegistry')) as ServiceProviderRegistry,
    lRegistry: (await ethers.getContract('LineRegistry')) as LineRegistry,
    tRegistry: (await ethers.getContract('TimestampRegistry')) as TimestampRegistry,
    stays: (await ethers.getContract('Stays')) as Stays
  }
  const users = await setupUsers(await getUnnamedAccounts(), contracts)

  return {
    users,
    deployer: await setupUser(deployer, contracts),
    alice: await setupUser(alice, contracts),
    bob: await setupUser(bob, contracts),
    carol: await setupUser(carol, contracts),
    api: await setupUser(api, contracts),
    bidder: await setupUser(bidder, contracts),
    manager: await setupUser(manager, contracts),
    staff: await setupUser(staff, contracts),
    ...contracts
  }
})

describe('Stays', function () {
  let deployer: { address: string } & {
    erc20: MockERC20
    vat: Vat
    join: GemJoin
    spRegistry: ServiceProviderRegistry
    lRegistry: LineRegistry
    tRegistry: TimestampRegistry
    stays: Stays
  }
  let alice: { address: string } & {
    erc20: MockERC20
    vat: Vat
    join: GemJoin
    spRegistry: ServiceProviderRegistry
    lRegistry: LineRegistry
    tRegistry: TimestampRegistry
    stays: Stays
  }
  let bob: { address: string } & {
    erc20: MockERC20
    vat: Vat
    join: GemJoin
    spRegistry: ServiceProviderRegistry
    lRegistry: LineRegistry
    tRegistry: TimestampRegistry
    stays: Stays
  }
  let api: { address: string } & {
    erc20: MockERC20
    vat: Vat
    join: GemJoin
    spRegistry: ServiceProviderRegistry
    lRegistry: LineRegistry
    tRegistry: TimestampRegistry
    stays: Stays
  }
  let bidder: { address: string } & {
    erc20: MockERC20
    vat: Vat
    join: GemJoin
    spRegistry: ServiceProviderRegistry
    lRegistry: LineRegistry
    tRegistry: TimestampRegistry
    stays: Stays
  }
  let manager: { address: string } & {
    erc20: MockERC20
    vat: Vat
    join: GemJoin
    spRegistry: ServiceProviderRegistry
    lRegistry: LineRegistry
    tRegistry: TimestampRegistry
    stays: Stays
  }
  let staff: { address: string } & {
    erc20: MockERC20
    vat: Vat
    join: GemJoin
    spRegistry: ServiceProviderRegistry
    lRegistry: LineRegistry
    tRegistry: TimestampRegistry
    stays: Stays
  }

  let serviceProvider: string

  beforeEach('load fixture', async () => {
    // eslint-disable-next-line @typescript-eslint/no-extra-semi
    ;({ deployer, alice, bob, api, bidder, manager, staff } = await setup())

    // authorise the Stays contract to use the `vat`
    await deployer.vat.rely(deployer.stays.address)

    // authorise the GemJoin contract to use the `vat`
    await deployer.vat.rely(deployer.join.address)

    // register the industry (line)
    await deployer.lRegistry['file(bytes32,bytes32,address)'](
      utils.formatBytes32String('terms'),
      LINE,
      deployer.stays.address
    )

    // add bob to the whitelist for registering
    await deployer.spRegistry.grantRole(WHITELIST_ROLE, bob.address)

    // register a service provider
    serviceProvider = await bob.spRegistry.callStatic.enroll(SP_SALT)
    console.log('Setup serviceProvider:', serviceProvider)

    // use multicall to batch everything together in an atomic transaction for the service provider registry!
    await bob.spRegistry.multicall([
      // enroll
      ServiceProviderRegistry__factory.createInterface().encodeFunctionData('enroll', [SP_SALT]),
      // api-role
      ServiceProviderRegistry__factory.createInterface().encodeFunctionData('grantRole', [
        utils.keccak256(utils.solidityPack(['bytes32', 'uint256'], [serviceProvider, API_ROLE])),
        api.address
      ]),
      // api-role
      ServiceProviderRegistry__factory.createInterface().encodeFunctionData('grantRole', [
        utils.keccak256(utils.solidityPack(['bytes32', 'uint256'], [serviceProvider, BIDDER_ROLE])),
        bidder.address
      ]),
      // api-role
      ServiceProviderRegistry__factory.createInterface().encodeFunctionData('grantRole', [
        utils.keccak256(utils.solidityPack(['bytes32', 'uint256'], [serviceProvider, MANAGER_ROLE])),
        manager.address
      ]),
      // api-role
      ServiceProviderRegistry__factory.createInterface().encodeFunctionData('grantRole', [
        utils.keccak256(utils.solidityPack(['bytes32', 'uint256'], [serviceProvider, STAFF_ROLE])),
        staff.address
      ])
    ])

    // register the service provider with the line
    await bob.lRegistry.register(LINE, serviceProvider)

    // give some erc20 tokens to the alice
    await deployer.erc20.mint(alice.address, utils.parseEther('10000'))
  })

  context('Check setup', async () => {
    it('correctly sets up vat for stays', async () => {
      expect(await alice.stays.vat()).to.be.eq(alice.vat.address)
    })
    it('correctly sets the account privileges', async () => {
      console.log('Service provider:', serviceProvider)
      expect(await deployer.spRegistry.can(serviceProvider, API_ROLE, api.address)).to.be.eq(true)
      expect(await deployer.spRegistry.can(serviceProvider, BIDDER_ROLE, bidder.address)).to.be.eq(true)
      expect(await deployer.spRegistry.can(serviceProvider, MANAGER_ROLE, manager.address)).to.be.eq(true)
      expect(await deployer.spRegistry.can(serviceProvider, STAFF_ROLE, staff.address)).to.be.eq(true)
    })
  })

  context('Do a deal', async () => {
    it('does a deal', async () => {
      expect(await deployer.spRegistry.can(serviceProvider, BIDDER_ROLE, bidder.address)).to.be.eq(true)
      const stayTypes: Record<string, TypedDataField[]> = {
        DateTime: [
          { name: 'yr', type: 'uint16' },
          { name: 'mon', type: 'uint8' },
          { name: 'day', type: 'uint8' },
          { name: 'hr', type: 'uint8' },
          { name: 'min', type: 'uint8' },
          { name: 'sec', type: 'uint8' }
        ],
        Stay: [
          { name: 'checkIn', type: 'DateTime' },
          { name: 'checkOut', type: 'DateTime' },
          { name: 'numPaxAdult', type: 'uint32' },
          { name: 'numPaxChild', type: 'uint32' },
          { name: 'numSpacesReq', type: 'uint32' }
        ]
      }

      const encoder = utils._TypedDataEncoder

      const stayRecords = {
        checkIn: { yr: 2022, mon: 5, day: 17, hr: 10, min: 0, sec: 0 },
        checkOut: { yr: 2022, mon: 5, day: 19, hr: 10, min: 0, sec: 0 },
        numPaxAdult: 2,
        numPaxChild: 0,
        numSpacesReq: 1
      }

      const bidRecords = {
        salt: utils.formatBytes32String('SALTHERE'),
        limit: 10,
        expiry: Math.floor(Date.now() / 1000) + 60 * 20,
        which: serviceProvider,
        params: encoder.hashStruct('Stay', stayTypes, stayRecords),
        items: [utils.arrayify(utils.formatBytes32String('ITEM-A'))],
        terms: [],
        options: {
          items: [],
          terms: []
        },
        cost: [
          {
            gem: alice.erc20.address,
            wad: utils.parseEther('100')
          }
        ]
      }

      // const stayAbiEncoded = utils.defaultAbiCoder.encode(
      //   [
      //     'tuple(tuple(uint16 yr,uint8 mon,uint8 day,uint8 hr,uint8 min,uint8 sec) checkIn,tuple(uint16 yr,uint8 mon,uint8 day,uint8 hr,uint8 min,uint8 sec) checkOut,uint32 numPaxAdult,uint32 numPaxChild,uint32 numSpacesReq)'
      //   ],
      //   [stayRecords]
      // )

      const bidderSigner = await ethers.getSigner(bidder.address)
      console.log('Bidder signer address:', bidderSigner.address)

      const domain = {
        name: 'stays',
        version: '1',
        chainId: 31337,
        verifyingContract: alice.stays.address
      }

      console.log('Hashstruct', encoder.hashStruct('Bid', bidask.Bid, bidRecords))
      console.log('Hashdomain', encoder.hashDomain(domain))

      const signature = await bidderSigner._signTypedData(domain, bidask.Bid, bidRecords)
      console.log('EIP-712 signature', signature)

      console.log(encoder.from(bidask.Bid))

      expect(utils.verifyTypedData(domain, bidask.Bid, bidRecords, signature)).to.be.eq(bidder.address)

      await alice.erc20.increaseAllowance(alice.join.address, utils.parseEther('2000'))
      await alice.join.join(alice.address, utils.parseEther('2000'))

      await alice.stays.deal(
        alice.erc20.address,
        bidRecords,
        stayRecords,
        {
          items: [],
          terms: []
        },
        [signature]
      )
      // await expect().to.not.be.reverted
    })
  })
  /*
  context('Metadata', async () => {
    it('sets symbol correctly', async () => {
      expect(await alice.erc20.symbol()).to.be.eq('MTK')
      expect(await alice.erc20.name()).to.be.eq('MockERC20')
    })
  })

  context('Allocations', async () => {
    it('gives correct amount to alice', async () => {
      expect(await alice.erc20.balanceOf(alice.address)).to.be.eq(utils.parseEther('1000000'))
    })
    it('gives correct amount to bob', async () => {
      expect(await bob.erc20.balanceOf(alice.address)).to.be.eq(utils.parseEther('1000000'))
    })
    it('gives correct amount to carol', async () => {
      expect(await carol.erc20.balanceOf(alice.address)).to.be.eq(utils.parseEther('1000000'))
    })
  })*/
})
