import Foundation
import NetworkExtension

final class PacketTunnelProvider: NEPacketTunnelProvider {
    override func startTunnel(
        options: [String: NSObject]?,
        completionHandler: @escaping (Error?) -> Void
    ) {
        let configuration = (protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration ?? [:]
        let tunnelIp = configuration["tunnelIp"] as? String ?? "10.44.0.1/32"
        let mtu = (configuration["mtu"] as? NSNumber)?.intValue ?? 1280

        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "192.0.2.1")
        settings.mtu = NSNumber(value: mtu)

        if let parsed = parseIPv4CIDR(tunnelIp) {
            let ipv4 = NEIPv4Settings(addresses: [parsed.address], subnetMasks: [parsed.mask])
            ipv4.includedRoutes = []
            settings.ipv4Settings = ipv4
        }

        setTunnelNetworkSettings(settings, completionHandler: completionHandler)
    }

    override func stopTunnel(
        with reason: NEProviderStopReason,
        completionHandler: @escaping () -> Void
    ) {
        completionHandler()
    }
}

private func parseIPv4CIDR(_ value: String) -> (address: String, mask: String)? {
    let parts = value.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
    guard let address = parts.first.map(String.init), !address.isEmpty else {
        return nil
    }
    let prefix = parts.count == 2 ? Int(parts[1]) ?? 32 : 32
    guard (0...32).contains(prefix) else {
        return nil
    }
    return (address, ipv4Mask(prefixLength: prefix))
}

private func ipv4Mask(prefixLength: Int) -> String {
    guard prefixLength > 0 else {
        return "0.0.0.0"
    }
    let value = prefixLength == 32 ? UInt32.max : UInt32.max << UInt32(32 - prefixLength)
    return [
        String((value >> 24) & 0xff),
        String((value >> 16) & 0xff),
        String((value >> 8) & 0xff),
        String(value & 0xff),
    ].joined(separator: ".")
}
