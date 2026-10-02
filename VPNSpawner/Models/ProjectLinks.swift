import Foundation

/// Public pages in the open-source repo.
enum ProjectLinks {
    private static let repo = "https://github.com/solomonxie/vpn-spawner"

    static let setupGuide = URL(string: "\(repo)/blob/master/docs/setup.md")!
    static let awsSetup = URL(string: "\(repo)/blob/master/docs/setup.md#aws")!
    static let tencentSetup = URL(string: "\(repo)/blob/master/docs/setup.md#tencent-cloud")!
    static let privacyPolicy = URL(string: "\(repo)/blob/master/docs/release/privacy-policy.md")!
}
