import Foundation

/// Where a person who is not going to open a GitHub issue can write.
///
/// The Diagnostics pane offered "Report on GitHub" alone, which is the right
/// door for the people running the app today and the wrong one for the buyer
/// PLAN §2.1.11 describes. One constant, used by About and Diagnostics, so
/// the address has one home.
enum SupportContact {
    static let email = "help@bgreen.lol"

    static var mailtoURL: URL? { URL(string: "mailto:\(email)") }
}
