// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Phase0HarnessLogic",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
    ],
    products: [
        .library(name: "Phase0HarnessLogic", targets: ["Phase0HarnessLogic"]),
    ],
    targets: [
        .target(
            name: "Phase0HarnessLogic",
            path: "Phase0Harness",
            exclude: [
                "AppDelegate.swift",
                "DeviceMonitors.swift",
                "HIDUsageAdapter.h",
                "HIDUsageAdapter.m",
                "HarnessViewController.swift",
                "IMEInputProxy.swift",
                "NativeRDPSession.swift",
                "Phase0Harness-Bridging-Header.h",
                "RemoteSurfaceView.swift",
                "SceneDelegate.swift",
            ],
            sources: [
                "BGRADesktopUpdateValidator.swift",
                "ConnectionSessionModels.swift",
                "EventJournal.swift",
                "InputModels.swift",
                "InputRouter.swift",
                "KeyRepeatScheduler.swift",
                "OrderedMainActorDeliveryQueue.swift",
                "RDPScanCodeMapper.swift",
                "ScrollWheelAccumulator.swift",
                "ServerTrustEvaluator.swift",
            ],
            linkerSettings: [
                .linkedFramework("Security"),
            ]
        ),
        .testTarget(
            name: "Phase0HarnessLogicTests",
            dependencies: ["Phase0HarnessLogic"],
            path: "Phase0HarnessTests"
        ),
    ]
)
