import Foundation
import ArgumentParser
import MonoDeckCore
import Darwin

struct MutationOptions: ParsableArguments {
    @Flag(help: "Validate and show the operation plan without modifying workspace resources.") var dryRun = false
    @Flag(help: "Confirm the current deletion plan without prompting. Safety checks still apply.") var yes = false
}

func runMutation(options: Options, mutation: MutationOptions,
                 preview: () async -> OperationResult,
                 execute: (OperationPlan?) async -> OperationResult) async -> Never {
    var result = await preview()
    result.dryRun = mutation.dryRun
    guard result.status == .success, !mutation.dryRun else { finish(result, json: options.json) }
    if let deletions = result.plan?.deletions, !deletions.isEmpty, !mutation.yes {
        guard !options.json, isatty(STDIN_FILENO) == 1 else {
            result.status = .confirmationRequired; result.reasonCode = "confirmation-required"
            finish(result, json: options.json)
        }
        guard confirm(deletions) else {
            result.status = .cancelled; result.reasonCode = "cancelled"
            finish(result, json: options.json)
        }
    }
    guard !Task.isCancelled else {
        result.status = .cancelled; result.reasonCode = "cancelled"
        finish(result, json: options.json)
    }
    finish(await execute(result.plan), json: options.json)
}
