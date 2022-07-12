import { HardhatRuntimeEnvironment } from 'hardhat/types'
import { DeployFunction } from 'hardhat-deploy/types'
import { ethers } from 'hardhat'
import { utils } from 'ethers'

const func: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const { deployments, getNamedAccounts, network } = hre
  const { deploy } = deployments

  const { deployer, alice, bob, carol, api, bidder, manager, staff } = await getNamedAccounts()

  // --- Account listing ---
  console.log(`Deployer: ${deployer}`)
  console.log(`Alice: ${alice}`)
  console.log(`Bob: ${bob}`)
  console.log(`Carol: ${carol}`)
  console.log(`API: ${api}`)
  console.log(`BIDDER: ${bidder}`)
  console.log(`MANAGER: ${manager}`)
  console.log(`STAFF: ${staff}`)

  // --- Deploy the registries
  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  const timestampRegistryDeploy = await deploy('TimestampRegistry', {
    from: deployer,
    log: true,
    autoMine: true
  })

  // deploy the test tokens
  const mockERC20Deploy = await deploy('MockERC20', {
    from: deployer,
    log: true,
    autoMine: true
  })

  const serviceProviderRegistryDeploy = await deploy('ServiceProviderRegistry', {
    from: deployer,
    log: true,
    autoMine: true,
    args: [Number(60 * 60 * 24 * 180).toString()]
  })

  const lineRegistryDeploy = await deploy('LineRegistry', {
    from: deployer,
    log: true,
    autoMine: true,
    args: [serviceProviderRegistryDeploy.address, '1']
  })

  const vatDeploy = await deploy('Vat', {
    from: deployer,
    log: true,
    autoMine: true
  })

  const gemJoinDeploy = await deploy('GemJoin', {
    from: deployer,
    log: true,
    autoMine: true,
    args: [vatDeploy.address, mockERC20Deploy.address]
  })

  const staysDeploy = await deploy('Stays', {
    from: deployer,
    log: true,
    autoMine: true,
    args: [
      vatDeploy.address,
      serviceProviderRegistryDeploy.address,
      lineRegistryDeploy.address,
      utils.formatBytes32String('stays'),
      'stays',
      '1'
    ]
  })

  // Test setup @todo move this feature to the separate script

  if (network.name !== 'hardhat') {
    console.log(`Detected ${network.name}. Development setup is skipped`)
    return
  }

  const WHITELIST_ROLE = ethers.utils.keccak256(utils.toUtf8Bytes('videre.roles.whitelist'))

  const vat = await ethers.getContract('Vat')
  const vatContract = vat.connect(await ethers.getSigner(deployer))

  // authorize the Stays contract to use the `vat`
  await vatContract.rely(staysDeploy.address)

  // authorize the GemJoin contract to use the `vat`
  await vatContract.rely(gemJoinDeploy.address)

  const lRegistry = await ethers.getContract('LineRegistry')
  const lRegistryContract = lRegistry.connect(await ethers.getSigner(deployer))

  // register the industry (line)
  await lRegistryContract['file(bytes32,bytes32,address)'](
    utils.formatBytes32String('terms'),
    utils.formatBytes32String('stays'),
    staysDeploy.address
  )

  const serviceProviderRegistry = await ethers.getContract('ServiceProviderRegistry')
  const serviceProviderRegistryContract = serviceProviderRegistry.connect(await ethers.getSigner(deployer))

  // Whitelist some addresses
  const whitelist = await Promise.all([
    serviceProviderRegistryContract.grantRole(WHITELIST_ROLE, '0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266')
  ])
  const resp = await Promise.all(whitelist.map((w) => w.wait()))
  console.log(
    'Whitelisted',
    resp.map((r) => r.events[0].args.account)
  )
}

export default func
func.tags = ['Stays']
