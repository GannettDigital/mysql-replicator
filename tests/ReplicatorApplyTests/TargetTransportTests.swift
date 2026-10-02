import XCTest
@testable import ReplicatorApply

extension ApplyTests {
    func testTargetTransportDefaultsToVerifiedTLS() throws {
        let target = try config().target
        try target.validate()
        XCTAssertTrue(target.requireTLS)
        XCTAssertNil(target.unixSocket)
        XCTAssertEqual(target.host,"target57")
    }

    func testUnixSocketAllowsExplicitLocalTransportWithoutTLS() throws {
        func decode(_ options: [String:Any]) throws -> TargetConfiguration {
            let base: [String:Any] = ["username":"apply","passwordEnvironment":"PASSWORD","nativeAutoStartDisabled":true]
            return try JSONDecoder().decode(TargetConfiguration.self,from:JSONSerialization.data(withJSONObject:base.merging(options){_,new in new}))
        }
        let local = try decode(["unixSocket":"/run/mysqld/mysqld.sock","requireTLS":false])
        try local.validate()
        XCTAssertNil(local.host)
        let encrypted = try decode(["unixSocket":"/run/mysqld/mysqld.sock","serverHostname":"target57"])
        try encrypted.validate()
        XCTAssertTrue(encrypted.requireTLS)
        for options: [String:Any] in [
            ["host":"127.0.0.1","port":3306,"requireTLS":false],
            ["unixSocket":"/run/mysql.sock","host":"target57","port":3306,"requireTLS":false],
            ["unixSocket":"relative.sock","requireTLS":false],
            ["unixSocket":"/run/mysql\0.sock","requireTLS":false],
            ["unixSocket":"/"+String(repeating:"x",count:103),"requireTLS":false],
            ["unixSocket":"/run/mysql.sock"],
            ["unixSocket":"/run/mysql.sock","requireTLS":false,"caFile":"/ca.pem"],
            ["requireTLS":false]
        ] { XCTAssertThrowsError(try decode(options).validate(),String(describing:options)) }
    }
}
