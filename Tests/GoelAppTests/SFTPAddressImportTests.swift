import XCTest
@testable import GoelApp

final class SFTPAddressImportTests: XCTestCase {

    func testURLFormsKeepHostPortUserAndPath() {
        XCTAssertEqual(SFTPAddress.parse("sftp://vinit@nas.local:2222/volume1/media"),
                       SFTPAddress(host: "nas.local", port: 2222, username: "vinit", path: "/volume1/media"))
        XCTAssertEqual(SFTPAddress.parse(" ssh://box.example "), SFTPAddress(host: "box.example"))
        XCTAssertEqual(SFTPAddress.parse("sftp://me:secret@h.example/")?.username, "me",
                       "a password in the URL is not carried over")
        XCTAssertEqual(SFTPAddress.parse("sftp://h.example/My%20Files")?.path, "/My Files")
    }

    func testScpAndBareForms() {
        XCTAssertEqual(SFTPAddress.parse("root@10.0.0.5:/srv/data"),
                       SFTPAddress(host: "10.0.0.5", username: "root", path: "/srv/data"))
        XCTAssertEqual(SFTPAddress.parse("host.example:2200"), SFTPAddress(host: "host.example", port: 2200))
        XCTAssertEqual(SFTPAddress.parse("user@[fe80::1]:22"),
                       SFTPAddress(host: "fe80::1", port: 22, username: "user"))
    }

    func testRejectsJunk() {
        XCTAssertNil(SFTPAddress.parse(""))
        XCTAssertNil(SFTPAddress.parse("https://example.com/file"))
        XCTAssertNil(SFTPAddress.parse("two words"))
        XCTAssertNil(SFTPAddress.parse("@host"))
    }

    func testSSHConfigParsesConcreteHostsFirstValueWins() {
        let config = """
        # personal
        Host nas
            HostName 192.168.0.234
            User vinit
            Port 2222
            IdentityFile ~/.ssh/id_ed25519
            Port 9999

        Host *.corp !skip
            User corp
        Host a b
          HostName=shared.example
          User  "spaced"
        Match host foo
          User nope
        Host *
          User everyone
        """
        let hosts = SSHConfigImport.parse(config)
        XCTAssertEqual(hosts.map(\.alias), ["nas", "a", "b"])
        let nas = hosts[0]
        XCTAssertEqual(nas.host, "192.168.0.234")
        XCTAssertEqual(nas.username, "vinit")
        XCTAssertEqual(nas.port, 2222)
        XCTAssertEqual(nas.identityFile, (("~/.ssh/id_ed25519") as NSString).expandingTildeInPath)
        XCTAssertEqual(hosts[1].host, "shared.example")
        XCTAssertEqual(hosts[2].username, "spaced")
    }
}
