//
//  OpenClickyAppSkillContext.swift
//  OpenClicky
//
//  Lightweight app-specific context adapted from the old clicky-with-skills fork.
//  This does not auto-open panels; it only gives voice/Tutor/Connect better
//  context when a recognized app is frontmost.
//

import AppKit
import Foundation

struct OpenClickyAppSkillWorkflow: Equatable {
    let name: String
    let steps: [String]
}

struct OpenClickyAppSkillContext: Equatable {
    let appName: String
    let bundleIdentifier: String
    let tagline: String
    let concepts: [String]
    let workflows: [OpenClickyAppSkillWorkflow]

    var promptFragment: String {
        let conceptText = concepts.map { "- \($0)" }.joined(separator: "\n")
        let workflowText = workflows.map { workflow in
            let steps = workflow.steps.enumerated().map { index, step in
                "  \(index + 1). \(step)"
            }.joined(separator: "\n")
            return "\(workflow.name):\n\(steps)"
        }.joined(separator: "\n\n")

        var prompt = """
        active app skill context:
        The frontmost app appears to be \(appName). \(tagline)

        Useful app concepts:
        \(conceptText)
        """

        if !workflowText.isEmpty {
            prompt += """

        Useful workflows:
        \(workflowText)
        """
        }

        prompt += """

        Use this only when it helps the user with the current app. Do not announce that a skill loaded. Keep voice answers natural and point at visible app areas when useful.
        """
        return prompt
    }

    static func contextForFrontmostApplication(excluding ownBundleIdentifier: String? = Bundle.main.bundleIdentifier) -> OpenClickyAppSkillContext? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.bundleIdentifier != ownBundleIdentifier else { return nil }
        return context(bundleIdentifier: app.bundleIdentifier, appName: app.localizedName)
    }

    static func context(bundleIdentifier: String?, appName: String?) -> OpenClickyAppSkillContext? {
        let normalizedBundleIdentifier = bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let normalizedBundleIdentifier,
           let exact = all.first(where: { $0.bundleIdentifier.lowercased() == normalizedBundleIdentifier }) {
            return exact
        }

        let normalizedAppName = appName?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        guard !normalizedAppName.isEmpty else { return nil }
        return all.first { context in
            let normalizedContextName = context.appName.lowercased()
            return normalizedAppName.contains(normalizedContextName)
                || normalizedContextName.contains(normalizedAppName)
                || aliases[context.bundleIdentifier, default: []].contains { normalizedAppName.contains($0) }
        }
    }

    private static let aliases: [String: [String]] = [
        "com.microsoft.VSCode": ["visual studio code", "code", "vscode"],
        "com.apple.FinalCut": ["final cut", "final cut pro"],
        "com.apple.dt.Xcode": ["xcode"],
        "com.adobe.AdobePremierePro": ["premiere", "premiere pro"],
        "org.blender.blender": ["blender"],
        "com.figma.Desktop": ["figma"],
        "com.microsoft.Excel": ["excel"],
        "notion.id": ["notion"],
        "com.apple.Terminal": ["terminal"],
        "com.shopify.shopify": ["shopify"]
    ]

    static let all: [OpenClickyAppSkillContext] = [
        OpenClickyAppSkillContext(
            appName: #"Adobe Premiere Pro"#,
            bundleIdentifier: #"com.adobe.AdobePremierePro"#,
            tagline: #"Industry-standard video editing software for film, TV, and web content."#,
            concepts: [
                #"Source and Program monitors — Source previews individual clips, Program shows timeline output"#,
                #"Timeline sequences — multi-track editor with video and audio layers"#,
                #"Effect Controls — keyframe animation for position, scale, rotation, opacity, and effects"#,
                #"Lumetri Color — color grading panel with basic correction, creative LUTs, curves, and wheels"#,
                #"Razor and Ripple Edit tools — C for cut, B for ripple delete to close gaps"#,
                #"Essential Graphics — create titles, text overlays, and motion graphics templates"#,
                #"Export settings — Ctrl+M for Media Encoder, choose codec, resolution, bitrate"#,
            ],
            workflows: [
                OpenClickyAppSkillWorkflow(
                    name: #"Basic edit workflow"#,
                    steps: [
                        #"Import media by dragging files into the Project panel or using Media Browser"#,
                        #"Create a new sequence (Ctrl+N) matching your footage settings"#,
                        #"Double-click a clip in the Project panel to open in Source Monitor"#,
                        #"Set In point (I) and Out point (O) on the clip"#,
                        #"Drag from Source Monitor to Timeline or press Insert (,) / Overwrite (.)"#,
                        #"Use Razor (C) to make cuts, Selection (V) to move clips, Ripple Edit (B) to close gaps"#,
                    ]
                ),
            ]
        ),
        OpenClickyAppSkillContext(
            appName: #"Final Cut Pro"#,
            bundleIdentifier: #"com.apple.FinalCut"#,
            tagline: #"Professional video editing for macOS with magnetic timeline and optimized playback."#,
            concepts: [
                #"Magnetic timeline — clips snap together, no gaps, connected clips sit above/below the primary storyline"#,
                #"Browser — libraries, events, and projects organize all media on the top left"#,
                #"Inspector panel — Cmd+3 for properties, audio, and effects tabs on selected clip"#,
                #"Color Inspector — Cmd+6 for color wheels, curves, and color board grading"#,
                #"Primary storyline — the main horizontal track that connected clips attach to"#,
                #"Connected clips — clips linked above/below the primary storyline, move with it"#,
                #"Retime controls — Cmd+R for speed changes, slow motion, and hold frames"#,
            ],
            workflows: [
                OpenClickyAppSkillWorkflow(
                    name: #"Apply color correction"#,
                    steps: [
                        #"Select a clip in the timeline"#,
                        #"Open Color Inspector with Cmd+6"#,
                        #"Adjust the Color Wheels — drag highlights, midtones, and shadows"#,
                        #"Use Curves for channel-specific corrections"#,
                        #"Option-click the viewer to see before/after comparison"#,
                        #"Copy color correction between clips with Cmd+C then Option+Cmd+V (Paste Attributes)"#,
                    ]
                ),
            ]
        ),
        OpenClickyAppSkillContext(
            appName: #"Terminal"#,
            bundleIdentifier: #"com.apple.Terminal"#,
            tagline: #"macOS command-line interface for shell operations, scripting, and system administration."#,
            concepts: [
                #"Shell commands and flags — pattern: command [-flags] [arguments], use 'man command' for help"#,
                #"Piping and redirection — | pipes output to next command, > writes to file, >> appends to file"#,
                #"Homebrew — 'brew install package' to install tools, 'brew search term' to find packages"#,
                #"File permissions — chmod (r=4 w=2 x=1), chown for ownership, ls -la to see permissions"#,
                #"Process management — Ctrl+C kill, Ctrl+Z suspend, bg/fg, top/htop for monitoring"#,
                #"Shell profiles — ~/.zshrc for zsh config, aliases, PATH, and prompt customization"#,
                #"Navigation shortcuts — Ctrl+A/E line start/end, Ctrl+R reverse search, Tab autocomplete"#,
            ],
            workflows: [
                OpenClickyAppSkillWorkflow(
                    name: #"Navigate and manipulate files"#,
                    steps: [
                        #"pwd to see current directory"#,
                        #"ls -la to list all files with details"#,
                        #"cd path/to/dir to navigate"#,
                        #"mkdir dirname to create directory, touch filename to create empty file"#,
                        #"cp source dest to copy, mv source dest to move/rename, rm file to delete"#,
                    ]
                ),
            ]
        ),
        OpenClickyAppSkillContext(
            appName: #"Xcode"#,
            bundleIdentifier: #"com.apple.dt.Xcode"#,
            tagline: #"Apple's IDE for developing iOS, macOS, watchOS, and tvOS apps with Swift and SwiftUI."#,
            concepts: [
                #"Navigator area — left sidebar with project files, source control, search (Cmd+1-8)"#,
                #"SwiftUI Previews — Cmd+Option+Enter, live-renders your UI beside the code"#,
                #"Inspector area — right sidebar for file, object, and attributes (Cmd+Option+1-7)"#,
                #"Debug area — bottom panel for variables, console, breakpoints (Cmd+Shift+Y)"#,
                #"Scheme selector — toolbar dropdown for build target, device, and run configuration"#,
                #"Asset catalog — Assets.xcassets for images, colors, and app icons"#,
                #"Source control — Cmd+2 for Git integration (commit, push, pull, branches)"#,
            ],
            workflows: [
                OpenClickyAppSkillWorkflow(
                    name: #"Build and run a project"#,
                    steps: [
                        #"Select target device/simulator from the scheme dropdown in the toolbar"#,
                        #"Press Cmd+R or click the Play button to build and run"#,
                        #"Check the Issue navigator (Cmd+4) for build errors"#,
                        #"Use the Debug area (Cmd+Shift+Y) for runtime errors and logging"#,
                        #"Press Cmd+. to stop a running app"#,
                    ]
                ),
            ]
        ),
        OpenClickyAppSkillContext(
            appName: #"Figma"#,
            bundleIdentifier: #"com.figma.Desktop"#,
            tagline: #"Collaborative interface design tool for UI/UX, prototyping, and design systems."#,
            concepts: [
                #"Auto Layout — flexbox-like layout, add with Shift+A, controls padding/gap/direction"#,
                #"Components — reusable design elements, create with Ctrl+Alt+K, edit Main Component to update all instances"#,
                #"Variants — multiple states of a component grouped together, switch in properties panel"#,
                #"Frames — layout containers, prefer over groups for responsive design"#,
                #"Instance overrides — change fill, text, or visibility per instance without breaking component link"#,
                #"Design panel vs Inspect panel — switch with top-right dropdown"#,
                #"Resources panel — access components, styles, and plugins (Shift+I)"#,
            ],
            workflows: [
                OpenClickyAppSkillWorkflow(
                    name: #"Create a component with variants"#,
                    steps: [
                        #"Select the element you want to make reusable"#,
                        #"Click the component icon or press Ctrl+Alt+K"#,
                        #"Add variants by selecting the component and clicking Add Variant in properties"#,
                        #"Name each variant with property/value pairs (e.g. State=Hover)"#,
                        #"Use the component from Assets panel in other frames"#,
                    ]
                ),
            ]
        ),
        OpenClickyAppSkillContext(
            appName: #"Microsoft Excel"#,
            bundleIdentifier: #"com.microsoft.Excel"#,
            tagline: #"Spreadsheet application for data analysis, calculation, and visualization."#,
            concepts: [
                #"Cell references — relative (A1), absolute ($A$1), mixed ($A1) — F4 to toggle"#,
                #"Formula bar — shows and edits cell contents above the grid"#,
                #"Pivot tables — Insert > PivotTable, drag fields to Rows/Columns/Values/Filters"#,
                #"Conditional formatting — Home tab, highlight cells based on rules"#,
                #"XLOOKUP/VLOOKUP — look up values across rows, XLOOKUP is more flexible"#,
                #"Data validation — restrict cell input to lists, ranges, or conditions"#,
                #"Named ranges — Formulas > Name Manager for readable formula references"#,
            ],
            workflows: [
                OpenClickyAppSkillWorkflow(
                    name: #"Create a pivot table"#,
                    steps: [
                        #"Select your data range including headers"#,
                        #"Go to Insert > PivotTable"#,
                        #"Choose where to place the pivot table (new or existing sheet)"#,
                        #"In the PivotTable Fields panel, drag fields to Rows, Columns, Values, and Filters"#,
                        #"Adjust value aggregation (sum, count, average) by clicking the field in Values area"#,
                    ]
                ),
            ]
        ),
        OpenClickyAppSkillContext(
            appName: #"VS Code"#,
            bundleIdentifier: #"com.microsoft.VSCode"#,
            tagline: #"Code editor with rich extension ecosystem for web, systems, and cloud development."#,
            concepts: [
                #"Command Palette — Ctrl+Shift+P (Cmd+Shift+P on Mac) for any action"#,
                #"Multi-cursor editing — Alt+Click, Ctrl+D select next, Ctrl+Shift+L select all"#,
                #"Integrated terminal — Ctrl+` to toggle, supports multiple terminals and split views"#,
                #"Extensions — install from marketplace for languages, linters, debuggers, themes"#,
                #"Workspace settings — .vscode/settings.json for project-specific configuration"#,
                #"Debug panel — set breakpoints, watch variables, step through code"#,
                #"Problems panel — Ctrl+Shift+M for diagnostics, errors, and warnings"#,
            ],
            workflows: [
                OpenClickyAppSkillWorkflow(
                    name: #"Find and replace across files"#,
                    steps: [
                        #"Press Ctrl+Shift+H (Cmd+Shift+H on Mac) for project-wide search and replace"#,
                        #"Type the search term"#,
                        #"Type the replacement"#,
                        #"Use the include/exclude filters to narrow scope"#,
                        #"Click Replace or Replace All"#,
                    ]
                ),
            ]
        ),
        OpenClickyAppSkillContext(
            appName: #"Shopify"#,
            bundleIdentifier: #"com.shopify.shopify"#,
            tagline: #"E-commerce platform for managing online stores, products, and orders."#,
            concepts: [
                #"Product management — add/edit products with title, description, variants, media, and pricing"#,
                #"Collections — group products by conditions (automated) or manual selection for storefront"#,
                #"Orders — view, fulfill, refund, and manage customer orders with payment/shipping status"#,
                #"Analytics dashboard — sales trends, top products, sessions, conversion rates"#,
                #"Online Store / Themes — customize storefront layout, sections, colors, and typography"#,
                #"Apps — Shopify App Store for adding payment, shipping, marketing integrations"#,
                #"Settings — payments (Shopify Payments, PayPal), shipping zones, taxes, and legal pages"#,
            ],
            workflows: [
                OpenClickyAppSkillWorkflow(
                    name: #"Add a new product"#,
                    steps: [
                        #"Go to Products > Add product"#,
                        #"Enter title and description"#,
                        #"Add media (photos, videos)"#,
                        #"Set pricing and compare-at price"#,
                        #"Configure inventory and shipping"#,
                        #"Add variants if the product has options (size, color)"#,
                    ]
                ),
            ]
        ),
        OpenClickyAppSkillContext(
            appName: #"Notion"#,
            bundleIdentifier: #"notion.id"#,
            tagline: #"All-in-one workspace for notes, docs, databases, and project management."#,
            concepts: [
                #"Blocks — everything is a block (text, image, embed), transform with /slash commands"#,
                #"Databases — structured data pages with multiple views (table, board, calendar, timeline, gallery)"#,
                #"Properties — columns in databases: text, select, date, people, formula, relation, rollup"#,
                #"Linked databases — embed the same database with different filters/sorts in multiple pages"#,
                #"Templates — pre-built page structures, create from page top right"#,
                #"Slash commands — type / to insert any block type or action"#,
                #"Views — switch between Table, Board, Calendar, Timeline, Gallery, and List for any database"#,
            ],
            workflows: [
                OpenClickyAppSkillWorkflow(
                    name: #"Create a linked database view"#,
                    steps: [
                        #"Type /linked and select Linked View of Database"#,
                        #"Choose the source database you want to reference"#,
                        #"Set filters to show only relevant items (e.g. Status = In Progress)"#,
                        #"Adjust sort order and visible properties"#,
                        #"The linked view stays synced with the original database"#,
                    ]
                ),
            ]
        ),
        OpenClickyAppSkillContext(
            appName: #"Blender"#,
            bundleIdentifier: #"org.blender.blender"#,
            tagline: #"3D creation suite for modeling, animation, rendering, and video editing."#,
            concepts: [
                #"Object mode vs Edit mode — Tab to toggle between them"#,
                #"3D Viewport shading modes — Z to cycle (Wireframe, Solid, Material Preview, Rendered)"#,
                #"Modifier stack — non-destructive, reorderable in Properties > Wrench tab"#,
                #"Shader nodes — visual node graph for materials in Shader Editor"#,
                #"Key shortcuts — G grab, R rotate, S scale, Shift+A add, X delete"#,
                #"Outliner panel — scene hierarchy on the top right"#,
                #"Properties panel — tabbed panel on bottom right (modifiers, materials, render settings)"#,
            ],
            workflows: [
                OpenClickyAppSkillWorkflow(
                    name: #"Add and edit a mesh"#,
                    steps: [
                        #"Press Shift+A in the 3D Viewport"#,
                        #"Choose Mesh and select a primitive (Cube, Sphere, etc.)"#,
                        #"Press Tab to enter Edit mode"#,
                        #"Select vertices/edges/faces and transform with G/R/S"#,
                        #"Press Tab to return to Object mode"#,
                    ]
                ),
                OpenClickyAppSkillWorkflow(
                    name: #"Set up a basic material"#,
                    steps: [
                        #"Select an object"#,
                        #"Go to Properties > Material tab (sphere icon)"#,
                        #"Click New to create a material"#,
                        #"Switch a viewport area to Shader Editor"#,
                        #"Adjust the Principled BSDF node values"#,
                        #"Set viewport shading to Material Preview or Rendered to see results"#,
                    ]
                ),
            ]
        )
    ]
}
