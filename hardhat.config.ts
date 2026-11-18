import hardhatToolboxViem from '@nomicfoundation/hardhat-toolbox-viem'
import { defineConfig } from 'hardhat/config'

const settings = {
	optimizer: { enabled: true, runs: 200 },
	evmVersion: 'cancun',
} as const

export default defineConfig({
	plugins: [hardhatToolboxViem],
	solidity: {
		profiles: {
			default: { version: '0.8.28', settings },
			production: { version: '0.8.28', settings: { ...settings, viaIR: true } },
		},
	},
	paths: {
		tests: { solidity: './test' },
	},
	test: {
		solidity: {
			fuzz: { runs: 256 },
			invariant: { runs: 256, depth: 64, failOnRevert: false },
		},
	},
})
