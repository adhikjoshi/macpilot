import AppKit
import ApplicationServices
import Foundation

struct ModalDialogInfo {
    let title: String
    let buttons: [String]
    let role: String
    let isModal: Bool
}

struct ModalDialogButtonMatch {
    let title: String
    let element: AXUIElement
}

struct ModalDialogMatch {
    let info: ModalDialogInfo
    let buttons: [ModalDialogButtonMatch]
}

func detectFrontmostModalDialog() -> ModalDialogInfo? {
    findFrontmostModalDialogMatch()?.info
}

func modalDialogPayload(_ info: ModalDialogInfo) -> [String: Any] {
    [
        "title": info.title,
        "buttons": info.buttons,
        "role": info.role,
        "modal": info.isModal,
    ]
}

func findFrontmostModalDialogMatch() -> ModalDialogMatch? {
    guard let frontmost = NSWorkspace.shared.frontmostApplication else { return nil }
    let appElement = AXUIElementCreateApplication(frontmost.processIdentifier)

    let windows = axElementArrayAttribute(appElement, kAXWindowsAttribute)
    var candidates: [AXUIElement] = []
    var seen: Set<Int> = []

    for window in windows {
        collectDialogCandidates(
            from: window,
            depth: 0,
            maxDepth: 8,
            candidates: &candidates,
            seen: &seen
        )
    }

    if candidates.isEmpty {
        collectDialogCandidates(
            from: appElement,
            depth: 0,
            maxDepth: 8,
            candidates: &candidates,
            seen: &seen
        )
    }

    let matches = candidates.map(buildDialogMatch).filter { !$0.info.role.isEmpty }
    if matches.isEmpty {
        return nil
    }

    if let modal = matches.first(where: { $0.info.isModal }) {
        return modal
    }
    return matches.first
}

func findDialogButton(named buttonName: String, in buttons: [ModalDialogButtonMatch]) -> ModalDialogButtonMatch? {
    let normalizedTarget = normalizedLabel(buttonName)

    if let exact = buttons.first(where: {
        normalizedLabel($0.title) == normalizedTarget ||
            $0.title.localizedCaseInsensitiveCompare(buttonName) == .orderedSame
    }) {
        return exact
    }

    return buttons.first(where: {
        let normalizedButton = normalizedLabel($0.title)
        return normalizedButton.contains(normalizedTarget) || normalizedTarget.contains(normalizedButton)
    })
}

func preferredAutoDismissButton(in buttons: [ModalDialogButtonMatch]) -> ModalDialogButtonMatch? {
    let priorityGroups = [
        ["dontsave", "donotsave", "discard"],
        ["ok"],
        ["cancel"],
    ]

    for group in priorityGroups {
        if let match = buttons.first(where: { button in
            let normalized = normalizedLabel(button.title)
            return group.contains(where: { token in
                normalized == token || normalized.contains(token)
            })
        }) {
            return match
        }
    }

    return nil
}

private func buildDialogMatch(from dialog: AXUIElement) -> ModalDialogMatch {
    let role = axStringAttribute(dialog, kAXRoleAttribute) ?? ""
    let title = resolveDialogTitle(dialog)
    let modal = axBoolAttribute(dialog, kAXModalAttribute) ?? (role == "AXSheet" || role == "AXDialog")
    let buttons = collectDialogButtons(from: dialog, maxDepth: 8)
    let buttonTitles = buttons.map(\.title)

    return ModalDialogMatch(
        info: ModalDialogInfo(title: title, buttons: buttonTitles, role: role, isModal: modal),
        buttons: buttons
    )
}

private func collectDialogCandidates(
    from element: AXUIElement,
    depth: Int,
    maxDepth: Int,
    candidates: inout [AXUIElement],
    seen: inout Set<Int>
) {
    guard depth <= maxDepth else { return }

    let role = axStringAttribute(element, kAXRoleAttribute) ?? ""
    if role == "AXSheet" || role == "AXDialog" {
        let hash = Int(CFHash(element))
        if !seen.contains(hash) {
            seen.insert(hash)
            candidates.append(element)
        }
    }

    guard depth < maxDepth else { return }

    var children = axElementArrayAttribute(element, kAXChildrenAttribute)
    children.append(contentsOf: axElementArrayAttribute(element, "AXSheets"))

    for child in children {
        collectDialogCandidates(
            from: child,
            depth: depth + 1,
            maxDepth: maxDepth,
            candidates: &candidates,
            seen: &seen
        )
    }
}

private func collectDialogButtons(from element: AXUIElement, maxDepth: Int) -> [ModalDialogButtonMatch] {
    var buttons: [ModalDialogButtonMatch] = []
    var seenTitles: Set<String> = []

    func walk(_ current: AXUIElement, _ depth: Int) {
        guard depth <= maxDepth else { return }

        let role = axStringAttribute(current, kAXRoleAttribute) ?? ""
        if role == "AXButton" {
            let title = resolveElementLabel(current)
            if !title.isEmpty {
                let normalized = normalizedLabel(title)
                if !normalized.isEmpty, !seenTitles.contains(normalized) {
                    seenTitles.insert(normalized)
                    buttons.append(ModalDialogButtonMatch(title: title, element: current))
                }
            }
        }

        guard depth < maxDepth else { return }
        for child in axElementArrayAttribute(current, kAXChildrenAttribute) {
            walk(child, depth + 1)
        }
    }

    walk(element, 0)
    return buttons
}

private func resolveDialogTitle(_ dialog: AXUIElement) -> String {
    if let title = axStringAttribute(dialog, kAXTitleAttribute),
       !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        return title
    }

    if let description = axStringAttribute(dialog, kAXDescriptionAttribute),
       !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        return description
    }

    if let value = axStringAttribute(dialog, kAXValueAttribute),
       !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        return value
    }

    if let staticText = firstStaticText(in: dialog, depth: 0, maxDepth: 6),
       !staticText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        return staticText
    }

    return ""
}

private func firstStaticText(in element: AXUIElement, depth: Int, maxDepth: Int) -> String? {
    guard depth <= maxDepth else { return nil }

    let role = axStringAttribute(element, kAXRoleAttribute) ?? ""
    if role == "AXStaticText" {
        let label = resolveElementLabel(element)
        if !label.isEmpty {
            return label
        }
    }

    guard depth < maxDepth else { return nil }
    for child in axElementArrayAttribute(element, kAXChildrenAttribute) {
        if let label = firstStaticText(in: child, depth: depth + 1, maxDepth: maxDepth) {
            return label
        }
    }
    return nil
}

private func resolveElementLabel(_ element: AXUIElement) -> String {
    if let title = axStringAttribute(element, kAXTitleAttribute),
       !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        return title
    }

    if let value = axStringAttribute(element, kAXValueAttribute),
       !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        return value
    }

    if let description = axStringAttribute(element, kAXDescriptionAttribute),
       !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        return description
    }

    return ""
}

private func normalizedLabel(_ raw: String) -> String {
    let folded = raw
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)

    let scalars = folded.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
    return String(String.UnicodeScalarView(scalars))
}

private func axAnyAttribute(_ element: AXUIElement, _ attribute: String) -> AnyObject? {
    var value: AnyObject?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
        return nil
    }
    return value
}

private func axStringAttribute(_ element: AXUIElement, _ attribute: String) -> String? {
    axAnyAttribute(element, attribute) as? String
}

private func axBoolAttribute(_ element: AXUIElement, _ attribute: String) -> Bool? {
    axAnyAttribute(element, attribute) as? Bool
}

private func axElementArrayAttribute(_ element: AXUIElement, _ attribute: String) -> [AXUIElement] {
    (axAnyAttribute(element, attribute) as? [AXUIElement]) ?? []
}
