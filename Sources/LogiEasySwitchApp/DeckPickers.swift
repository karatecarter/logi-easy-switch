import AppKit
import SwiftUI

struct DeckChoice: Identifiable {
    var id: String
    var title: String
    var detail = ""
}

struct DeckSearchPicker: View {
    var title: String
    var selection: String
    var choices: [DeckChoice]
    var choose: (String) -> Void
    @State private var showing = false
    @State private var query = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption)
            Button { query = ""; showing = true } label: {
                HStack {
                    VStack(alignment: .leading) {
                        Text(choices.first { $0.id == selection }?.title ?? (selection.isEmpty ? "Choose…" : selection))
                        if !selection.isEmpty { Text(selection).font(.caption).foregroundStyle(.secondary) }
                    }
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down")
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.popover(isPresented: $showing) {
                VStack(alignment: .leading) {
                    TextField("Search \(title.lowercased())", text: $query)
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(choices.filter { query.isEmpty || ($0.title + " " + $0.id + " " + $0.detail).localizedCaseInsensitiveContains(query) }) { choice in
                                Button { choose(choice.id); showing = false } label: {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(choice.title)
                                        if !choice.detail.isEmpty { Text(choice.detail).font(.caption).foregroundStyle(.secondary) }
                                    }.padding(8).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                                }.buttonStyle(.plain)
                            }
                        }
                    }
                }.padding(12).frame(width: 420, height: 340)
            }
        }
    }
}

struct DeckIconPicker: View {
    @Binding var icon: String
    @State private var showing = false
    @State private var query = ""
    // A browsable library of general-purpose symbols available on the supported OS.
    static let symbols = "square.grid.2x2 folder folder.fill star star.fill heart heart.fill bolt bolt.fill power lightbulb lightbulb.fill lightbulb.slash lamp.desk lamp.floor lamp.ceiling sun.max sun.max.fill moon moon.fill sunrise sunset flashlight.on.fill house house.fill door.left.hand.open door.left.hand.closed lock lock.fill lock.open key key.fill window.horizontal window.vertical blinds.horizontal.closed fan fan.fill air.conditioner thermostat thermometer thermometer.sun snowflake flame drop drop.fill humidity cloud cloud.rain cloud.sun wind mic mic.fill mic.slash.fill speaker speaker.fill speaker.slash.fill speaker.wave.1.fill speaker.wave.2.fill speaker.wave.3.fill headphones music.note music.note.list play.fill pause.fill stop.fill forward.fill backward.fill video video.fill video.slash.fill camera camera.fill tv display desktopcomputer laptopcomputer keyboard computermouse printer wifi network antenna.radiowaves.left.and.right globe bluetooth battery.100 battery.25 battery.0 bell bell.fill bell.slash alarm clock timer calendar checkmark checkmark.circle xmark xmark.circle plus minus arrow.up arrow.down arrow.left arrow.right arrow.clockwise arrow.triangle.2.circlepath gearshape wrench screwdriver hammer trash tray envelope phone phone.fill message person person.2 figure.walk car car.fill bicycle bed.double cup.and.saucer fork.knife leaf tree water.waves book bookmark magnifyingglass eye eye.slash record.circle circle circle.fill square square.fill triangle diamond hexagon app gift gamecontroller command option control shift return escape".split(separator: " ").map(String.init)
    var body: some View {
        HStack {
            Text("Symbol")
            Button { showing = true; query = "" } label: {
                Label("Choose icon…", systemImage: icon).labelStyle(.titleAndIcon)
            }.popover(isPresented: $showing) {
                VStack(alignment: .leading) {
                    Text("Choose an icon").font(.headline)
                    TextField("Search icons (lightbulb, microphone, folder…)", text: $query)
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 68))], spacing: 8) {
                            ForEach(Self.symbols.filter { NSImage(systemSymbolName: $0, accessibilityDescription: nil) != nil && matches($0) }, id: \.self) { symbol in
                                Button { icon = symbol; showing = false } label: {
                                    Image(systemName: symbol).font(.system(size: 25)).frame(width: 60, height: 50)
                                        .background(icon == symbol ? Color.accentColor.opacity(0.2) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                                }.buttonStyle(.plain).help(symbol).accessibilityLabel(symbol)
                            }
                        }
                    }
                }.padding(16).frame(width: 450, height: 380)
            }
        }
    }
    private func matches(_ symbol: String) -> Bool {
        let aliases = symbol.hasPrefix("mic") ? " microphone mute audio" : symbol.hasPrefix("lightbulb") ? " light lights bulb" : symbol.hasPrefix("speaker") ? " volume audio mute sound" : ""
        return query.isEmpty || (symbol + aliases).localizedCaseInsensitiveContains(query)
    }
}
