import test from 'node:test'
import assert from 'node:assert/strict'

import { shouldShowVpnDataDisclosure } from './vpn-disclosure.js'

const baseState = {
  platform: 'ios',
  vpnSessionControlSupported: true,
  sessionActive: false,
}

test('VPN data disclosure is shown before iOS VPN use', () => {
  assert.equal(shouldShowVpnDataDisclosure(baseState), true)
})

test('VPN data disclosure stays off outside the iOS pre-connect state', () => {
  assert.equal(shouldShowVpnDataDisclosure({ ...baseState, platform: 'android' }), false)
  assert.equal(shouldShowVpnDataDisclosure({ ...baseState, platform: 'desktop' }), false)
  assert.equal(shouldShowVpnDataDisclosure({ ...baseState, sessionActive: true }), false)
  assert.equal(shouldShowVpnDataDisclosure({ ...baseState, vpnSessionControlSupported: false }), false)
})
