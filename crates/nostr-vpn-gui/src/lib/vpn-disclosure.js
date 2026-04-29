export const shouldShowVpnDataDisclosure = (state) =>
  Boolean(
    state &&
      state.platform === 'ios' &&
      state.vpnSessionControlSupported &&
      !state.sessionActive,
  )
