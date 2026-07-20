// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Ryan Tenney.

import Foundation
import Network
import NetworkExtension
import CoreLocation
import CoreTelephony

/// A snapshot of the network conditions a speed test ran under.
struct SpeedTestNetworkContext {
    var networkType: String?
    var wifiSSID: String?
    var carrierName: String?
    var radioTechnology: String?
    var locationDescription: String?
    var latitude: Double?
    var longitude: Double?
}

/// Collects best-effort metadata about the current network environment:
/// interface type (Wi-Fi / Cellular / Wired), Wi-Fi SSID (requires the
/// Access Wi-Fi Info entitlement plus location authorization), cellular
/// carrier and radio technology (LTE / 5G), and a one-shot reverse-geocoded
/// location. Everything is optional and the collector always completes,
/// within `timeout` at the latest.
final class SpeedTestMetadataCollector: NSObject {

    private static var activeCollectors = [SpeedTestMetadataCollector]()

    private var context = SpeedTestNetworkContext()
    private let group = DispatchGroup()
    private var didComplete = false
    private var completion: ((SpeedTestNetworkContext) -> Void)?
    private var locationManager: CLLocationManager?
    private var pathMonitor: NWPathMonitor?
    private var isWaitingForLocation = false

    static func collect(timeout: TimeInterval = 8, completion: @escaping (SpeedTestNetworkContext) -> Void) {
        let collector = SpeedTestMetadataCollector()
        activeCollectors.append(collector)
        collector.completion = completion
        DispatchQueue.main.async {
            collector.startCollecting(timeout: timeout)
        }
    }

    private func startCollecting(timeout: TimeInterval) {
        collectCarrierInfo()
        collectPathInfo()
        collectWifiSSID()
        collectLocation()

        group.notify(queue: .main) { [weak self] in
            self?.complete()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
            self?.complete()
        }
    }

    private func complete() {
        guard !didComplete else { return }
        didComplete = true
        pathMonitor?.cancel()
        pathMonitor = nil
        locationManager?.delegate = nil
        locationManager = nil

        // With a VPN active the path's interface is the utun, so fall back to
        // heuristics: a readable SSID means Wi-Fi; an attached radio without
        // an SSID most likely means cellular.
        if context.networkType == nil {
            if context.wifiSSID != nil {
                context.networkType = "Wi-Fi"
            } else if context.radioTechnology != nil {
                context.networkType = "Cellular"
            }
        }

        completion?(context)
        completion = nil
        SpeedTestMetadataCollector.activeCollectors.removeAll { $0 === self }
    }

    // MARK: - Interface type

    private func collectPathInfo() {
        group.enter()
        let monitor = NWPathMonitor()
        pathMonitor = monitor
        var didReport = false
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self = self, !didReport else { return }
            didReport = true
            DispatchQueue.main.async {
                if self.pathUsesType(path, .wifi) {
                    self.context.networkType = "Wi-Fi"
                } else if self.pathUsesType(path, .cellular) {
                    self.context.networkType = "Cellular"
                } else if self.pathUsesType(path, .wiredEthernet) {
                    self.context.networkType = "Wired"
                }
                self.group.leave()
            }
        }
        monitor.start(queue: DispatchQueue(label: "SpeedTest.PathMonitor"))
    }

    private func pathUsesType(_ path: NWPath, _ type: NWInterface.InterfaceType) -> Bool {
        return path.usesInterfaceType(type) || path.availableInterfaces.contains { $0.type == type }
    }

    // MARK: - Wi-Fi SSID

    private func collectWifiSSID() {
        group.enter()
        NEHotspotNetwork.fetchCurrent { [weak self] network in
            DispatchQueue.main.async {
                self?.context.wifiSSID = network?.ssid
                self?.group.leave()
            }
        }
    }

    // MARK: - Cellular

    private func collectCarrierInfo() {
        let telephonyInfo = CTTelephonyNetworkInfo()
        let serviceId = telephonyInfo.dataServiceIdentifier

        if let radioTechnologies = telephonyInfo.serviceCurrentRadioAccessTechnology, !radioTechnologies.isEmpty {
            let radio = serviceId.flatMap { radioTechnologies[$0] } ?? radioTechnologies.values.first
            context.radioTechnology = radio.map { SpeedTestMetadataCollector.radioDisplayName($0) }
        }
        if let carriers = telephonyInfo.serviceSubscriberCellularProviders, !carriers.isEmpty {
            let carrier = serviceId.flatMap { carriers[$0] } ?? carriers.values.first
            if let carrierName = carrier?.carrierName, !carrierName.isEmpty, carrierName != "--" {
                context.carrierName = carrierName
            }
        }
    }

    private static func radioDisplayName(_ radioAccessTechnology: String) -> String {
        switch radioAccessTechnology {
        case CTRadioAccessTechnologyNR:
            return "5G"
        case CTRadioAccessTechnologyNRNSA:
            return "5G (NSA)"
        case CTRadioAccessTechnologyLTE:
            return "LTE"
        case CTRadioAccessTechnologyWCDMA, CTRadioAccessTechnologyHSDPA, CTRadioAccessTechnologyHSUPA, CTRadioAccessTechnologyCDMAEVDORev0, CTRadioAccessTechnologyCDMAEVDORevA, CTRadioAccessTechnologyCDMAEVDORevB, CTRadioAccessTechnologyeHRPD:
            return "3G"
        case CTRadioAccessTechnologyEdge, CTRadioAccessTechnologyGPRS, CTRadioAccessTechnologyCDMA1x:
            return "2G"
        default:
            return radioAccessTechnology
        }
    }

    // MARK: - Location

    private func collectLocation() {
        let manager = CLLocationManager()
        locationManager = manager
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters

        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            group.enter()
            isWaitingForLocation = true
            manager.requestLocation()
        case .notDetermined:
            group.enter()
            isWaitingForLocation = true
            manager.requestWhenInUseAuthorization()
        default:
            break
        }
    }

    private func finishLocation() {
        if isWaitingForLocation {
            isWaitingForLocation = false
            group.leave()
        }
    }
}

extension SpeedTestMetadataCollector: CLLocationManagerDelegate {

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard isWaitingForLocation else { return }
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            manager.requestLocation()
        case .notDetermined:
            break
        default:
            finishLocation()
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard isWaitingForLocation, let location = locations.last else {
            finishLocation()
            return
        }
        context.latitude = location.coordinate.latitude
        context.longitude = location.coordinate.longitude

        CLGeocoder().reverseGeocodeLocation(location) { [weak self] placemarks, _ in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if let placemark = placemarks?.first {
                    let parts = [placemark.locality, placemark.administrativeArea, placemark.isoCountryCode].compactMap { $0 }
                    if !parts.isEmpty {
                        self.context.locationDescription = parts.joined(separator: ", ")
                    }
                }
                self.finishLocation()
            }
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        finishLocation()
    }
}
