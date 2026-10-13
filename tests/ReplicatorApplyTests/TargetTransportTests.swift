import XCTest
import NIOSSL
@testable import ReplicatorApply

extension ApplyTests {
    func testTargetTransportDefaultsToVerifiedTLS() throws {
        let target = try config().target
        try target.validate()
        XCTAssertTrue(target.requireTLS)
        XCTAssertEqual(target.tlsVerification, .verifyIdentity)
        XCTAssertEqual(target.tlsConfiguration()?.certificateVerification, .fullVerification)
        XCTAssertFalse(target.explicitTableLocks)
        XCTAssertNil(target.unixSocket)
        XCTAssertEqual(target.host,"target57")
    }

    func testVerifyCARequiresExplicitTrustAndMakesHostnameOptional() throws {
        func decode(_ options: [String:Any]) throws -> TargetConfiguration {
            let base: [String:Any] = ["host":"127.0.0.1","port":3306,"username":"apply",
                                     "password":"secret","nativeAutoStartDisabled":true,
                                     "tlsVerification":"verify-ca"]
            return try JSONDecoder().decode(TargetConfiguration.self,from:JSONSerialization.data(withJSONObject:base.merging(options){_,new in new}))
        }
        let target = try decode(["caFile":"/instance-ca.pem"])
        try target.validate()
        XCTAssertNil(target.serverHostname)
        XCTAssertTrue(target.requireTLS)
        XCTAssertEqual(target.tlsConfiguration()?.certificateVerification, .noHostnameVerification)
        try decode(["caFile":"/instance-ca.pem","serverHostname":"optional-sni.example"]).validate()
        for options: [String:Any] in [
            [:], ["caFile":""], ["caFile":"/ca.pem","serverHostname":""],
            ["caFile":"/ca.pem","tlsVerification":"verify-identity"],
            ["caFile":"/ca.pem","requireTLS":false],
            ["caFile":"/ca.pem","tlsVerification":"none"],
            ["caFile":"/ca.pem","tlsVerification":"verify-typo"]
        ] { XCTAssertThrowsError(try decode(options).validate(), String(describing:options)) }
    }

    func testUnixSocketAllowsExplicitLocalTransportWithoutTLS() throws {
        func decode(_ options: [String:Any]) throws -> TargetConfiguration {
            let base: [String:Any] = ["username":"apply","passwordEnvironment":"PASSWORD","nativeAutoStartDisabled":true]
            return try JSONDecoder().decode(TargetConfiguration.self,from:JSONSerialization.data(withJSONObject:base.merging(options){_,new in new}))
        }
        let local = try decode(["unixSocket":"/run/mysqld/mysqld.sock","requireTLS":false,"explicitTableLocks":true])
        try local.validate()
        XCTAssertNil(local.host)
        XCTAssertNil(local.tlsConfiguration())
        XCTAssertTrue(local.explicitTableLocks)
        let tcp = try decode(["host":"127.0.0.1","port":3306,"requireTLS":false])
        try tcp.validate()
        XCTAssertFalse(tcp.requireTLS)
        XCTAssertNil(tcp.tlsConfiguration())
        XCTAssertNil(tcp.serverHostname)
        let encrypted = try decode(["unixSocket":"/run/mysqld/mysqld.sock","serverHostname":"target57"])
        try encrypted.validate()
        XCTAssertTrue(encrypted.requireTLS)
        for options: [String:Any] in [
            ["host":"127.0.0.1","port":3306,"requireTLS":false,"serverHostname":"target"],
            ["unixSocket":"/run/mysql.sock","host":"target57","port":3306,"requireTLS":false],
            ["unixSocket":"relative.sock","requireTLS":false],
            ["unixSocket":"/run/mysql\0.sock","requireTLS":false],
            ["unixSocket":"/"+String(repeating:"x",count:103),"requireTLS":false],
            ["unixSocket":"/run/mysql.sock"],
            ["unixSocket":"/run/mysql.sock","requireTLS":false,"caFile":"/ca.pem"],
            ["unixSocket":"/run/mysql.sock","requireTLS":false,"tlsVerification":"verify-ca"],
            ["requireTLS":false]
        ] { XCTAssertThrowsError(try decode(options).validate(),String(describing:options)) }
    }
}
