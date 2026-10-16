enum LoadPhase<Value> {
    case idle
    case loading
    case loaded(Value)
    case failed(UserIssue)

    var value: Value? {
        if case .loaded(let value) = self { value } else { nil }
    }
}
