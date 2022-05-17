/* eslint-disable camelcase */
import { HardhatRuntimeEnvironment } from 'hardhat/types'
import { DeployFunction } from 'hardhat-deploy/types'
import { ethers } from 'hardhat'
import { utils } from 'ethers'
import { utils as vUtils } from '@windingtree/videre-sdk'

const func: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const { deployments, getNamedAccounts } = hre
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
    args: [
      'MockERC20GemJoin',
      '1',
      vatDeploy.address,
      mockERC20Deploy.address
    ]
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

  /*const staysFacilityDeploy = await deploy('StaysFacility', {
    from: deployer,
    log: true,
    autoMine: true, // speed up deployment on local network, no effect on live network.
    args: ['videre-stays', '1']
  })

  const eip712TestDeploy = await deploy('EIP712Test', {
    from: deployer,
    log: true,
    autoMine: true
  })

  if (staysFacilityDeploy.newlyDeployed) {
    console.log(
      `Contract StaysFacility deployed at ${staysFacilityDeploy.address} using ${staysFacilityDeploy.receipt?.gasUsed} gas`
    )
  }

  if (eip712TestDeploy.newlyDeployed) {
    const t: EIP712Test = (await ethers.getContract('EIP712Test') as EIP712Test).connect(deployer)
    await t.test('0xad14be9b61541546e40287b09dc1d4b69867f1d86871729d7eabcaa6409c551544e591ac055988444db1f3d575e464bbe4abebcf45b12b18975d705b567dacab1c')
  }*/
}

export default func
func.tags = ['Stays']
