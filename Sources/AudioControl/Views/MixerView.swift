import SwiftUI

struct MixerView: View {
    let model: MixerViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            masterRow
            Divider()
            if model.showsPermissionBanner {
                permissionBanner
                Divider()
            }
            if model.rows.isEmpty {
                Text("No apps playing audio")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 8)
            } else {
                ForEach(model.rows) { row in
                    AppRowView(row: row, model: model)
                }
            }
            Divider()
            HStack {
                if model.liveChannelCount > 0 {
                    Button("Release all taps") { model.releaseAllTaps() }
                        .help("Stop adjusting every app until permission is re-checked. Apps return to full volume.")
                }
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
                    .keyboardShortcut("q")
            }
            .controlSize(.small)
        }
        .padding(12)
        .frame(width: 340)
    }

    private var permissionBanner: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(model.permissionBannerText).font(.caption).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button(model.permissionBannerButton) { model.permissionBannerAction() }
                Button("Check again") { model.checkPermissionAgain() }
                if !model.permissionUsesSPI {
                    Text("(status unavailable)").font(.caption2).foregroundStyle(.secondary)
                }
            }
            .controlSize(.small)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.orange.opacity(0.12)))
    }

    private var masterRow: some View {
        HStack(spacing: 8) {
            Button {
                model.setMasterMuted(!(model.masterMuted ?? false))
            } label: {
                Image(systemName: (model.masterMuted ?? false) ? "speaker.slash.fill" : "speaker.wave.3.fill")
                    .frame(width: 20)
            }
            .buttonStyle(.plain)
            .disabled(!model.canSetMasterMute)
            .help(model.outputName)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.outputName).font(.subheadline).lineLimit(1)
                Slider(value: Binding(get: { Double(model.masterVolume ?? 0) },
                                      set: { model.setMasterVolume(Float($0)) }), in: 0...1)
                    .disabled(!model.canSetMasterVolume)
                    .controlSize(.small)
            }
            Text(model.masterVolume.map { "\(Int(($0 * 100).rounded()))%" } ?? "—")
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 36, alignment: .trailing)
        }
    }
}

struct AppRowView: View {
    let row: MixerViewModel.AppRow
    let model: MixerViewModel

    var body: some View {
        HStack(spacing: 8) {
            Group {
                if let icon = row.icon {
                    Image(nsImage: icon).resizable()
                } else {
                    Image(systemName: "app.dashed")
                }
            }
            .frame(width: 20, height: 20)
            .opacity(row.isPlaying ? 1 : 0.5)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(row.name).font(.subheadline).lineLimit(1)
                    if row.isWebKit {
                        Image(systemName: "info.circle").foregroundStyle(.secondary).font(.caption)
                            .help("Safari and all WebKit apps share these audio processes; this setting affects all of them.")
                    }
                    if row.routingFailed {
                        Image(systemName: "xmark.octagon.fill").foregroundStyle(.red).font(.caption)
                            .help("Couldn't route \(row.name); playing at full volume. Move the slider to 100% and back to retry.")
                    } else if row.isStarved {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.caption)
                            .help("No audio arriving from \(row.name) although it reports playing. If it is really playing, check System Audio Recording permission.")
                    } else if row.isLive {
                        Circle().fill(.green).frame(width: 6, height: 6)
                            .help("Volume is being applied")
                    }
                }
                Slider(value: Binding(get: { Double(row.volume) },
                                      set: { model.setVolume(Float($0), for: row.key) }), in: 0...1)
                    .controlSize(.small)
            }
            Text("\(Int((row.volume * 100).rounded()))%")
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 36, alignment: .trailing)
            Button { model.setMuted(!row.isMuted, for: row.key) } label: {
                Image(systemName: row.isMuted ? "speaker.slash.fill" : "speaker.wave.2").frame(width: 18)
            }
            .buttonStyle(.plain)
            .foregroundStyle(row.isMuted ? .red : .primary)
        }
    }
}
