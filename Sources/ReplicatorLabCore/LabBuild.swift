import Foundation

enum LabBuild {
    static func prepare(root: URL, build: Bool, coverage: Bool) throws -> String {
        let runner=ProcessRunner(root:root), tag=coverage ? CodeCoverage.image : "mysql-replicator-packaging:lab"
        let digest=try DDLCoverageEvidence.digest(DDLCoverageEvidence.inputs(root:root))
        let labels=["--label",DDLCoverageEvidence.imageLabel+"="+digest]
        if build {
            if coverage { try CodeCoverage.build(runner,labels:labels) }
            else {
                _ = try runner.run(["docker","build","--platform","linux/amd64","--target","runtime","-f","docker/packaging/Dockerfile","-t",tag]+labels+["."],timeout:3600,onOutput:{ FileHandle.standardError.write($0) })
            }
        }
        let image=try runner.run(["docker","image","inspect",tag,"--format","{{.Id}}"] ).text
        try CodeCoverage.validate(runner,image:image,enabled:coverage)
        let actual=try runner.run(["docker","image","inspect",image,"--format","{{index .Config.Labels \"\(DDLCoverageEvidence.imageLabel)\"}}"] ).text
        try require(actual == digest,"lab image inputs differ; rerun without --skip-build")
        return image
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
        try require(suite == "correctness" || (family == nil && ids.isEmpty),"--case and --family select shared correctness scenarios")
        let sharedRecovery=suite == "recovery" && profiles == [.forward]
        try require(!coverage || sharedRecovery || ["correctness","lifecycle"].contains(suite),"--coverage collects shared correctness, lifecycle and forward recovery runs")
        try require(variants == [.standard] || sharedRecovery || ["correctness","lifecycle"].contains(suite),"--variant selects shared correctness or lifecycle; adapters retain their own variants")
        _ = try LabScenario.select(tier:tier,family:family,ids:ids)
    }
}
