import Foundation

public enum LabBuild {
    public static func inputDigest(root: URL) throws -> String {
        try DDLCoverageEvidence.digest(DDLCoverageEvidence.inputs(root:root))
    }
    static func prepare(root: URL, build: Bool, coverage: Bool, demo: Bool = false) throws -> String {
        let runner=ProcessRunner(root:root), tag=coverage ? CodeCoverage.image : (demo ? "mysql-replicator-packaging:lab-demo" : "mysql-replicator-packaging:lab")
        let digest=try inputDigest(root:root)
        let labels=["--label",DDLCoverageEvidence.imageLabel+"="+digest]
        if build {
            if coverage { try CodeCoverage.build(runner,labels:labels) }
            else {
                _ = try runner.run(["docker","build","--platform","linux/amd64","--target",demo ? "demo" : "runtime","-f","docker/packaging/Dockerfile","-t",tag]+labels+["."],timeout:3600,onOutput:{ FileHandle.standardError.write($0) })
            }
        }
        let image=try runner.run(["docker","image","inspect",tag,"--format","{{.Id}}"] ).text
        try CodeCoverage.validate(runner,image:image,enabled:coverage)
        let actual=try runner.run(["docker","image","inspect",image,"--format","{{index .Config.Labels \"\(DDLCoverageEvidence.imageLabel)\"}}"] ).text
        try require(actual == digest,"lab image inputs differ; rerun without --skip-build")
        // Docker's containerd image store can discard an untagged image name
        // when the shared build tag moves, even while a retained fixture needs
        // it for new CLI containers. Keep one stable tag per immutable image.
        _ = try runner.run(["docker","tag",image,retainedTag(image)])
        return image
    }
    static func retainedTag(_ image: String) -> String {
        "mysql-replicator-lab-pinned:"+image.replacingOccurrences(of:"sha256:",with:"")
    }
}

struct LabTestOptions {
    var profiles=LabProfile.allCases
    var suite="correctness", tier="full"
    var family: String?
    var variants: [LabVariant] = [.standard]
    var ids: Set<String> = []
    var list=false, build=true, coverage=false
    init(_ arguments: [String]) throws {
        var args=arguments
        while !args.isEmpty {
            let flag=args.removeFirst()
            if flag == "--list" { list=true; continue }
            if flag == "--skip-build" { build=false; continue }
            if flag == "--coverage" { coverage=true; continue }
            try require(!args.isEmpty,"missing value for "+flag)
            let value=args.removeFirst()
            switch flag {
            case "--variant":
                if value == "all" { variants=LabVariant.allCases }
                else { guard let variant=LabVariant(rawValue:value) else { throw LabError("unknown variant: "+value) }; variants=[variant] }
            case "--profile":
                if value == "all" { profiles=LabProfile.allCases }
                else { guard let p=LabProfile(rawValue:value) else { throw LabError("unknown profile: "+value) }; profiles=[p] }
            case "--suite": suite=value
            case "--tier": tier=value
            case "--family": family=value
            case "--case": ids.insert(value)
            default: throw LabError("unknown test option: "+flag)
            }
        }
        try require(["correctness","lifecycle","recovery","demo","native","all"].contains(suite),"unknown suite: "+suite)
        try require(["smoke","full"].contains(tier),"tier must be smoke or full")
        try require(tier == "full" || suite == "correctness", "--tier smoke selects shared correctness only; adapter suites retain their full scope")
        try require(["correctness","demo"].contains(suite) || (family == nil && ids.isEmpty),"--case and --family select correctness or demo scenarios")
        let sharedRecovery=suite == "recovery" && profiles == [.forward]
        try require(!coverage || sharedRecovery || ["correctness","lifecycle","demo"].contains(suite),"--coverage collects shared correctness, lifecycle, demo and forward recovery runs")
        try require(variants == [.standard] || sharedRecovery || ["correctness","lifecycle"].contains(suite),"--variant selects shared correctness or lifecycle; adapters retain their own variants")
        if suite == "demo" { _ = try LabDemoQualification.select(family:family,ids:ids) }
        else { _ = try LabScenario.select(tier:tier,family:family,ids:ids) }
    }
}
