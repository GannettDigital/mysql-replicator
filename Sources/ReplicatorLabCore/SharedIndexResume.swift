import Foundation

extension SharedCorrectness.Run {
    func indexResume() throws {
        guard selects(ModifyIndexCases.resume.id) else { return }
        try resetNativeEngine(); try f.awaitNative()
        let test=ModifyIndexCases.cases.first { $0.test.id == "ddl-index-create" }!
        let isolated=LabIsolatedApply(f), label=ModifyIndexCases.resume.id
        for role in LabProfile.Role.allCases { _ = try f.sql(role,test.seed) }
        try reporter.run(ModifyIndexCases.resume) {
            var config=isolated.configuration(label,at:try f.boundary(),count:1+test.workload.count)
            let initial=try isolated.start(label+"-initial",config:config)
            _ = try f.sql(.source,session+test.sql)
            for step in test.workload { _ = try f.sql(.source,session+step.sql) }
            _ = try isolated.finish(initial,label:label+"-initial",config:config)
            try f.awaitNative()
            var source=config["source"] as! [String:Any]; source["stopAfterTransactions"]=1; config["source"]=source
            let resumed=try isolated.start(label,config:config,initialize:false)
            _ = try f.sql(.source,"INSERT INTO demo.mi VALUES(4,'resumed',4,NULL)")
            let result=try isolated.finish(resumed,label:label,config:config)
            try f.awaitNative()
            try require(result["transactionsApplied"] as? Int == 5 && result["rowsApplied"] as? Int == 4 && result["ddlApplied"] as? Int == 1,"indexed resume reset/replayed counters")
            for role in LabProfile.Role.allCases {
                try require(ModifyIndexCases.rows(f.h,f.profile.service(role),test.table) == test.retained+"\n4\t726573756D6564\t4\tNULL","indexed resume rows differ")
            }
            _ = try f.sql(.target,"CREATE INDEX external_drift ON demo.mi(n)")
            let refused=try isolated.start(label+"-drift",config:config,initialize:false)
            _ = try isolated.finish(refused,label:label+"-drift",config:config,reason:"target schema differs from saved checkpoint")
            try require(isolated.state(label+"-drift","SELECT transactions_applied||'|'||rows_applied FROM state") == "5|4","drift refusal advanced counters")
        }
    }
}
