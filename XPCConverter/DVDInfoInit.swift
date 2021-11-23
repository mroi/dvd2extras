import MovieArchiveConverter
import LibDVDRead


/* MARK: Toplevel */

extension DVDInfo {
	init?(_ ifoData: DVDData.IFO.All) {
		guard let vmgi = ifoData[.vmgi]?.pointee else { return nil }
		guard let vmgiMat = vmgi.vmgi_mat?.pointee else { return nil }
		self.init(specification: Version(vmgiMat.specification_version),
		          category: vmgiMat.vmg_category,
		          provider: String(tuple: vmgiMat.provider_identifier),
		          posCode: vmgiMat.vmg_pos_code,
		          totalVolumeCount: vmgiMat.vmg_nr_of_volumes,
		          volumeIndex: vmgiMat.vmg_this_volume_nr,
		          discSide: vmgiMat.disc_side,
		          start: ProgramChain(vmgi.first_play_pgc?.pointee),
		          topLevelMenus: Domain(vmgi.pgci_ut?.pointee, vmgiMat))
	}
}

private extension DVDInfo.Version {
	init(_ combined: UInt8) {
		self.init(major: combined.bits(4...7), minor: combined.bits(0...3))
	}
}

private extension DVDInfo.Time {
	init(_ time: dvd_time_t) {
		// dvd_time_t is in binary coded decimals
		func bcd(_ value: UInt8) -> UInt8 {
			value.bits(0...3) + 10 * value.bits(4...7)
		}
		self.init(hours: bcd(time.hour),
		          minutes: bcd(time.minute),
		          seconds: bcd(time.second),
		          frames: bcd(time.frame_u.bits(0...5)),
		          rate: FrameRate(time.frame_u))
	}
}

private extension DVDInfo.Time.FrameRate {
	init(_ frameInfo: UInt8) {
		switch frameInfo.bits(6...7) {
		case 1: self = .framesPerSecond(25.00)
		case 3: self = .framesPerSecond(29.97)
		default: self = .unexpected(frameInfo)
		}
	}
}


/* MARK: Domain */

private extension DVDInfo.Domain {
	init(_ pgcUt: pgci_ut_t?, _ vmgiMat: vmgi_mat_t) {
		let pgcs = Self.convert(pgcsPerLanguage: pgcUt)
		self.init(programChains: ProgramChains(mapping: Dictionary(mapping: pgcs),
		                                       storage: Dictionary(storage: pgcs)),
		          video: VideoAttributes(vmgiMat.vmgm_video_attr),
		          audio: vmgiMat.nr_of_vmgm_audio_streams == 0 ? [:] : [0: AudioAttributes(vmgiMat.vmgm_audio_attr)],
		          subpicture: vmgiMat.nr_of_vmgm_subp_streams == 0 ? [:] : [0: SubpictureAttributes(vmgiMat.vmgm_subp_attr)])
	}
	static func convert(pgcsPerLanguage pgcUt: pgci_ut_t?) -> [pgci_lu_t: [pgci_srp_t]] {
		let languagesStart = pgcUt?.lu
		let languagesCount = pgcUt?.nr_of_lus
		let languagesBuffer = UnsafeBufferPointer(start: languagesStart, count: languagesCount)
		let languages = languagesBuffer.compactMap { $0.pgcit != nil ? $0 : nil }

		let laungagePgcs = languages.map { convert(pgcs: $0.pgcit?.pointee) }
		return Dictionary(uniqueKeysWithValues: zip(languages, laungagePgcs))
	}
	static func convert(pgcs pgcIt: pgcit_t?) -> [pgci_srp_t] {
		let pgcInfosStart = pgcIt?.pgci_srp
		let pgcInfosCount = pgcIt?.nr_of_pgci_srp
		let pgcInfosBuffer = UnsafeBufferPointer(start: pgcInfosStart, count: pgcInfosCount)
		return Array(pgcInfosBuffer)
	}
}

private extension Dictionary where Key == DVDInfo.Domain.ProgramChains.Descriptor, Value == DVDInfo.Domain.ProgramChains.Id {
	init(mapping pgcs: [pgci_lu_t: [pgci_srp_t]]) {
		self.init(minimumCapacity: pgcs.map(\.value.count).reduce(0, +))
		for (language, pgcs) in pgcs {
			for (index, pgcInfo) in zip(1..., pgcs) {
				let menuType = Key.MenuType(pgcInfo.entry_id.bits(0...3))
				let descriptor = Key.menu(language: String(twoCharacters: language.lang_code),
				                          index: DVDInfo.Index(index),
				                          entryPoint: pgcInfo.entry_id.bit(7),
				                          type: pgcInfo.entry_id.bit(7) ? menuType : nil)
				self[descriptor] = Value(languageId: language.lang_start_byte,
				                         programChainId: pgcInfo.pgc_start_byte)
			}
		}
	}
}

private extension Dictionary where Key == DVDInfo.Domain.ProgramChains.Id, Value == DVDInfo.ProgramChain {
	init(storage pgcs: [pgci_lu_t: [pgci_srp_t]]) {
		self.init(minimumCapacity: pgcs.map(\.value.count).reduce(0, +))
		for (language, pgcs) in pgcs {
			for pgcInfo in pgcs {
				guard let pgc = pgcInfo.pgc?.pointee else { continue }
				let id = Key(languageId: language.lang_start_byte,
				             programChainId: pgcInfo.pgc_start_byte)
				self[id] = Value(pgc)
			}
		}
	}
}

private extension DVDInfo.Domain.ProgramChains.Descriptor.MenuType {
	init(_ entry: UInt8) {
		switch entry {
		case 2: self = .titles
		case 3: self = .rootWithinTitle
		case 4: self = .subpicture
		case 5: self = .audio
		case 6: self = .viewingAngle
		case 7: self = .chapter
		default: self = .unexpected(entry)
		}
	}
}

private extension DVDInfo.Domain.VideoAttributes {
	init(_ attrs: video_attr_t) {
		let standard = VideoStandard(attrs.video_format)
		var allowedDisplay = DisplayModification()
		if !attrs.permitted_df.bit(0) { allowedDisplay.update(with: .letterbox) }
		if !attrs.permitted_df.bit(1) { allowedDisplay.update(with: .panScan) }
		var line21cc = Line21ClosedCaption()
		if attrs.line21_cc_1 != 0 { line21cc.update(with: .firstField) }
		if attrs.line21_cc_2 != 0 { line21cc.update(with: .secondField) }
		self.init(coding: CodingType(attrs.mpeg_version),
		          standard: standard,
		          codedPicture: Resolution(attrs.picture_size, videoStandard: standard),
		          displayAspect: AspectRatio(attrs.display_aspect_ratio, letterboxed: attrs.letterboxed != 0),
		          allowedDisplay: allowedDisplay,
		          line21cc: line21cc,
		          content: ContentInfo(attrs.film_mode))
	}
}

private extension DVDInfo.Domain.VideoAttributes.CodingType {
	init(_ mpegVersion: UInt8) {
		switch mpegVersion {
		case 0: self = .mpeg1
		case 1: self = .mpeg2
		default: self = .unexpected(mpegVersion)
		}
	}
}

private extension DVDInfo.Domain.VideoAttributes.VideoStandard {
	init(_ videoFormat: UInt8) {
		switch videoFormat {
		case 0: self = .ntsc
		case 1: self = .pal
		default: self = .unexpected(videoFormat)
		}
	}
}

private extension DVDInfo.Domain.VideoAttributes.Resolution {
	init(_ pictureSize: UInt8, videoStandard standard: DVDInfo.Domain.VideoAttributes.VideoStandard) {
		var width, height: UInt16?
		switch standard {
		case .ntsc: height = 480
		case .pal: height = 576
		default: height = nil
		}
		switch pictureSize {
		case 0: width = 720
		case 1: width = 704
		case 2: width = 352
		case 3:
			width = 352
			height = height.map { $0 / 2 }
		default:
			width = nil
			height = nil
		}
		self.init(width: width, height: height)
	}
}

private extension DVDInfo.Domain.VideoAttributes.AspectRatio {
	init(_ displayAspectRatio: UInt8, letterboxed: Bool) {
		switch displayAspectRatio {
		case 0: self = .classic(letterboxed: letterboxed)
		case 1: self = .unspecified
		case 3: self = .wide
		default: self = .unexpected(displayAspectRatio)
		}
	}
}

private extension DVDInfo.Domain.VideoAttributes.ContentInfo {
	init(_ filmMode: UInt8) {
		switch filmMode {
		case 0: self = .video
		case 1: self = .film
		default: fatalError("illegal value \(filmMode)")
		}
	}
}

private extension DVDInfo.Domain.AudioAttributes {
	init(_ attrs: audio_attr_t, karaoke: multichannel_ext_t? = nil) {
		self.init(coding: CodingType(attrs.audio_format, additional: attrs.quantization),
		          sampleFrequency: UInt32(attrs.sample_frequency == 0 ? 48000 : 96000),
		          channelCount: attrs.channels + 1,
		          rendering: RenderingIntent(attrs.application_mode, additional: attrs.app_info, karaoke: attrs.multichannel_extension != 0 ? karaoke : nil),
		          language: attrs.lang_type != 0 ? String(twoCharacters: attrs.lang_code) : nil,
		          content: ContentInfo(attrs.code_extension))
	}
}

private extension DVDInfo.Domain.AudioAttributes.CodingType {
	init(_ audioFormat: UInt8, additional info: UInt8) {
		switch audioFormat {
		case 0: self = .ac3
		case 2: self = .mpeg1(dynamicRangeCompression: info != 0)
		case 3: self = .mpeg2(dynamicRangeCompression: info != 0)
		case 4:
			switch info {
			case 0: self = .lpcm(bitsPerSample: 16)
			case 1: self = .lpcm(bitsPerSample: 20)
			case 2: self = .lpcm(bitsPerSample: 24)
			default: self = .unexpected(audioFormat, info)
			}
		case 6: self = .dts
		default: self = .unexpected(audioFormat, info)
		}
	}
}

private extension DVDInfo.Domain.AudioAttributes.RenderingIntent {
	init(_ applicationMode: UInt8, additional info: audio_attr_t.__Unnamed_union_app_info, karaoke multiChannel: multichannel_ext_t?) {
		switch applicationMode {
		case 0: self = .normal
		case 1: self = .karaoke(version: info.karaoke.version,
		                        mode: Karaoke.Mode(info.karaoke.mode),
		                        channels: multiChannel != nil ? Array(multiChannel!) : Array(info.karaoke.channel_assignment),
		                        multiChannelIntro: info.karaoke.mc_intro == 0)
		case 2: self = .surround(dolbyMatrixEncoded: info.surround.dolby_encoded != 0)
		default: self = .unexpected(applicationMode)
		}
	}
}

private extension DVDInfo.Domain.AudioAttributes.RenderingIntent.Karaoke.Mode {
	init(_ mode: UInt8) {
		switch mode {
		case 0: self = .solo
		case 1: self = .duet
		default: fatalError("illegal value \(mode)")
		}
	}
}

private extension Array where Element == DVDInfo.Domain.AudioAttributes.RenderingIntent.Karaoke.Channel {
	init(_ multiChannel: multichannel_ext_t) {
		self = [.left, .right, .center, .surround, .surround]
		if multiChannel.ach0_gme != 0 { self[0] = .guideMelody() }
		if multiChannel.ach1_gme != 0 { self[1] = .guideMelody() }
		if multiChannel.ach2_gm1e != 0 { self[2] = .guideMelody("1") }
		if multiChannel.ach2_gm2e != 0 { self[2] = .guideMelody("2") }
		if multiChannel.ach2_gv1e != 0 { self[2] = .guideVocal("1") }
		if multiChannel.ach2_gv2e != 0 { self[2] = .guideVocal("2") }
		if multiChannel.ach3_gmAe != 0 { self[3] = .guideMelody("A") }
		if multiChannel.ach3_gv1e != 0 { self[3] = .guideVocal("1") }
		if multiChannel.ach3_gv2e != 0 { self[3] = .guideVocal("2") }
		if multiChannel.ach3_se2e != 0 { self[3] = .effect("A") }
		if multiChannel.ach4_gmBe != 0 { self[4] = .guideMelody("B") }
		if multiChannel.ach4_gv1e != 0 { self[4] = .guideVocal("1") }
		if multiChannel.ach4_gv2e != 0 { self[4] = .guideVocal("2") }
		if multiChannel.ach4_seBe != 0 { self[4] = .effect("B") }
	}
	init(_ channelAssignment: UInt8) {
		switch channelAssignment {
		case 2: self = [.left, .right]
		case 3: self = [.left, .guideMelody(), .right]
		case 4: self = [.left, .right, .guideVocal()]
		case 5: self = [.left, .guideMelody(), .right, .guideVocal()]
		case 6: self = [.left, .right, .guideVocal("1"), .guideVocal("2")]
		case 7: self = [.left, .guideMelody(), .right, .guideVocal("1"), .guideVocal("2")]
		default: self = []
		}
	}
}

private extension DVDInfo.Domain.AudioAttributes.ContentInfo {
	init(_ codeExtension: UInt8) {
		switch codeExtension {
		case 0: self = .unspecified
		case 1: self = .sourceAudio
		case 2: self = .audioDescription
		case 3: self = .commentary
		case 4: self = .alternateCommentary
		default: self = .unexpected(codeExtension)
		}
	}
}

private extension DVDInfo.Domain.SubpictureAttributes {
	init(_ attrs: subp_attr_t) {
		self.init(coding: CodingType(attrs.code_mode),
		          language: attrs.type != 0 ? String(twoCharacters: attrs.lang_code) : nil,
		          content: ContentInfo(attrs.code_extension))
	}
}

private extension DVDInfo.Domain.SubpictureAttributes.CodingType {
	init(_ codeMode: UInt8) {
		switch codeMode {
		case 0: self = .rle
		case 1: self = .extended
		default: self = .unexpected(codeMode)
		}
	}
}

private extension DVDInfo.Domain.SubpictureAttributes.ContentInfo {
	init(_ codeExtension: UInt8) {
		switch codeExtension {
		case 0: self = .unspecified
		case 1: self = .subtitles(fontSize: .normal, forChildren: false)
		case 2: self = .subtitles(fontSize: .large, forChildren: false)
		case 3: self = .subtitles(fontSize: .normal, forChildren: true)
		case 5: self = .closedCaptions(fontSize: .normal, forChildren: false)
		case 6: self = .closedCaptions(fontSize: .large, forChildren: false)
		case 7: self = .closedCaptions(fontSize: .normal, forChildren: true)
		case 9: self = .forced
		case 13: self = .commentary(fontSize: .normal, forChildren: false)
		case 14: self = .commentary(fontSize: .large, forChildren: false)
		case 15: self = .commentary(fontSize: .normal, forChildren: true)
		default: self = .unexpected(codeExtension)
		}
	}
}


/* MARK: Program Chain */

private extension DVDInfo.ProgramChain {
	init(_ pgc: pgc_t) {
		let programsStart = pgc.program_map
		let programsCount = pgc.nr_of_programs
		let programsBuffer = UnsafeBufferPointer(start: programsStart, count: programsCount)
		let programs = Array(programsBuffer)

		let cellsStart = pgc.cell_playback
		let cellsCount = pgc.nr_of_cells
		let cellsBuffer = UnsafeBufferPointer(start: cellsStart, count: cellsCount)
		let cells = Array(cellsBuffer)

		let pre: [vm_cmd_t]
		let post: [vm_cmd_t]
		let cellPost: [vm_cmd_t]
		if let cmd = pgc.command_tbl?.pointee {
			let preStart = cmd.pre_cmds
			let preCount = cmd.nr_of_pre
			let preBuffer = UnsafeBufferPointer(start: preStart, count: preCount)
			pre = Array(preBuffer)
			let postStart = cmd.post_cmds
			let postCount = cmd.nr_of_post
			let postBuffer = UnsafeBufferPointer(start: postStart, count: postCount)
			post = Array(postBuffer)
			let cellStart = cmd.cell_cmds
			let cellCount = cmd.nr_of_cell
			let cellBuffer = UnsafeBufferPointer(start: cellStart, count: cellCount)
			cellPost = Array(cellBuffer)
		} else {
			pre = []; post = []; cellPost = []
		}

		self.init(programs: Dictionary(uniqueKeysWithValues: zip(1..., programs.map(Program.init))),
		          cells: Dictionary(uniqueKeysWithValues: zip(1..., cells.map(Cell.init))),
		          duration: DVDInfo.Time(pgc.playback_time),
		          playback: PlaybackMode(pgc.pg_playback_mode),
		          ending: EndingMode(pgc.still_time),
		          mapAudio: Dictionary(audio: pgc.audio_control),
		          mapSubpicture: Dictionary(subpicture: pgc.subp_control),
		          next: pgc.next_pgc_nr != 0 ? DVDInfo.Reference(programChain: .init(pgc.next_pgc_nr)) : nil,
		          previous: pgc.prev_pgc_nr != 0 ? DVDInfo.Reference(programChain: .init(pgc.prev_pgc_nr)) : nil,
		          up: pgc.goup_pgc_nr != 0 ? DVDInfo.Reference(programChain: .init(pgc.goup_pgc_nr)) : nil,
		          pre: Dictionary(uniqueKeysWithValues: zip(1..., pre.map(DVDInfo.Command.init))),
		          post: Dictionary(uniqueKeysWithValues: zip(1..., post.map(DVDInfo.Command.init))),
		          cellPost: Dictionary(uniqueKeysWithValues: zip(1..., cellPost.map(DVDInfo.Command.init))),
		          buttonPalette: Dictionary(palette: pgc.palette),
		          restrictions: DVDInfo.Restrictions(pgc.prohibited_ops))
	}
	init?(_ pgc: pgc_t?) {
		guard let pgc = pgc else { return nil }
		self.init(pgc)
	}
}

private extension DVDInfo.ProgramChain.Program {
	init(_ program: pgc_program_map_t) {
		self.init(start: DVDInfo.Reference(cell: .init(program)))
	}
}

private extension DVDInfo.ProgramChain.Cell {
	init(_ cell: cell_playback_t) {
		var playback = PlaybackMode()
		if cell.seamless_play != 0 { playback.update(with: .seamless) }
		if cell.interleaved != 0 { playback.update(with: .interleaved) }
		if cell.stc_discontinuity != 0 { playback.update(with: .timeDiscontinuity) }
		if cell.seamless_angle != 0 { playback.update(with: .seamlessAngle) }
		if cell.playback_mode != 0 { playback.update(with: .allStillFrames) }
		if cell.restricted != 0 { playback.update(with: .stopFastForward) }
		self.init(duration: DVDInfo.Time(cell.playback_time),
		          playback: playback,
		          ending: EndingMode(cell.still_time),
		          angle: AngleInfo(block: cell.block_type, cell: cell.block_mode),
		          karaoke: KaraokeInfo(cell.cell_type),
		          post: cell.cell_cmd_nr != 0 ? DVDInfo.Reference(command: .init(cell.cell_cmd_nr)) : nil,
		          sectors: DVDInfo.Index<DVDInfo.Sector>(cell.first_sector)...DVDInfo.Index<DVDInfo.Sector>(cell.last_sector))
	}
}

private extension DVDInfo.ProgramChain.Cell.AngleInfo {
	init?(block: UInt32, cell: UInt32) {
		if block == 0 && cell == 0 {
			return nil
		} else if block == 1 {
			switch cell {
			case 0: self = .externalCell
			case 1: self = .firstCellInBlock
			case 2: self = .innerCellInBlock
			case 3: self = .lastCellInBlock
			default: fatalError("illegal value \(cell)")
			}
		} else {
			self = .unexpected(block)
		}
	}
}

private extension DVDInfo.ProgramChain.Cell.KaraokeInfo {
	init?(_ cellType: UInt32) {
		switch cellType {
		case 0: return nil
		case 1: self = .titlePicture
		case 2: self = .introduction
		case 3: self = .bridge
		case 4: self = .firstClimax
		case 5: self = .secondClimax
		case 6: self = .maleVocal
		case 7: self = .femaleVocal
		case 8: self = .mixedVocal
		case 9: self = .interlude
		case 10: self = .interludeFadeIn
		case 11: self = .interludeFadeOut
		case 12: self = .firstEnding
		case 13: self = .secondEnding
		default: self = .unexpected(cellType)
		}
	}
}

private extension DVDInfo.ProgramChain.PlaybackMode {
	init(_ playbackMode: UInt8) {
		if playbackMode == 0 {
			self = .sequential
		} else if playbackMode.bit(7) {
			self = .random(programCount: playbackMode.bits(0...6) + 1)
		} else {
			self = .shuffle(programCount: playbackMode.bits(0...6) + 1)
		}
	}
}

private extension DVDInfo.ProgramChain.EndingMode {
	init(_ still: UInt8) {
		switch still {
		case UInt8.min: self = .immediate
		case UInt8.max: self = .holdLastFrameIndefinitely
		default: self = .holdLastFrame(seconds: still)
		}
	}
}

private extension Dictionary where Key == DVDInfo.Index<DVDInfo.LogicalAudioStream>, Value == DVDInfo.Index<DVDInfo.VOBAudioStream> {
	init(audio: (UInt16, UInt16, UInt16, UInt16, UInt16, UInt16, UInt16, UInt16)) {
		self.init()
		let elements = Array<UInt16>(tuple: audio)
		for (index, stream) in zip(0..., elements) where stream.bit(15) {
			self[Key(index)] = Value(stream.bits(8...10))
		}
	}
}

private extension Dictionary where Key == DVDInfo.Index<DVDInfo.LogicalSubpictureStream>, Value == [DVDInfo.ProgramChain.SubpictureDescriptor: DVDInfo.Index<DVDInfo.VOBSubpictureStream>] {
	init(subpicture: (UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32,
	                  UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32,
	                  UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32,
	                  UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32)) {
		self.init()
		let elements = Array<UInt32>(tuple: subpicture)
		for (index, stream) in zip(0..., elements) where stream.bit(31) {
			self[Key(index)] = [
				.classic:   DVDInfo.Index(stream.bits(24...28)),
				.wide:      DVDInfo.Index(stream.bits(16...20)),
				.letterbox: DVDInfo.Index(stream.bits(8...12)),
				.panScan:   DVDInfo.Index(stream.bits(0...4))
			]
		}
	}
}

private extension Dictionary where Key == DVDInfo.Index<Value>, Value == DVDInfo.ProgramChain.Color {
	init(palette: (UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32,
	               UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32)) {
		let elements = Array<UInt32>(tuple: palette)
		self.init(minimumCapacity: elements.count)
		for (index, color) in zip(0..., elements) {
			self[Key(index)] = Value(color)
		}
	}
}

private extension DVDInfo.ProgramChain.Color {
	init(_ color: UInt32) {
		self.init(Y: UInt8(color.bits(16...23)),
		          Cb: UInt8(color.bits(8...15)),
		          Cr: UInt8(color.bits(0...7)))
	}
}


/* MARK: Command */

private extension DVDInfo.Command {
	init(_ command: vm_cmd_t) {
		var combined: UInt64 = 0
		combined |= UInt64(command.bytes.0) << 56
		combined |= UInt64(command.bytes.1) << 48
		combined |= UInt64(command.bytes.2) << 40
		combined |= UInt64(command.bytes.3) << 32
		combined |= UInt64(command.bytes.4) << 24
		combined |= UInt64(command.bytes.5) << 16
		combined |= UInt64(command.bytes.6) <<  8
		combined |= UInt64(command.bytes.7) <<  0
		let command = combined

		// TODO: decode command
		self = .unexpected(command)
	}
}


/* MARK: Restrictions */

private extension DVDInfo.Restrictions {
	init(_ ops: user_ops_t) {
		self.init()
		if ops.title_or_time_play != 0 { self.update(with: .noJumpIntoTitle) }
		if ops.chapter_search_or_play != 0 { self.update(with: .noJumpToPart) }
		if ops.title_play != 0 { self.update(with: .noJumpToTitle) }
		if ops.stop != 0 { self.update(with: .noStop) }
		if ops.go_up != 0 { self.update(with: .noJumpUp) }
		if ops.time_or_chapter_search != 0 { self.update(with: .noJumpIntoPart) }
		if ops.prev_or_top_pg_search != 0 { self.update(with: .noProgramBackward) }
		if ops.next_pg_search != 0 { self.update(with: .noProgramForward) }
		if ops.forward_scan != 0 { self.update(with: .noSeekForward) }
		if ops.backward_scan != 0 { self.update(with: .noSeekBackward) }
		if ops.title_menu_call != 0 { self.update(with: .noJumpToTopLevelMenu) }
		if ops.root_menu_call != 0 { self.update(with: .noJumpToPerTitleMenu) }
		if ops.subpic_menu_call != 0 { self.update(with: .noJumpToSubpictureMenu) }
		if ops.audio_menu_call != 0 { self.update(with: .noJumpToAudioMenu) }
		if ops.angle_menu_call != 0 { self.update(with: .noJumpToViewingAngleMenu) }
		if ops.chapter_menu_call != 0 { self.update(with: .noJumpToChapterMenu) }
		if ops.resume != 0 { self.update(with: .noResumeFromMenu) }
		if ops.button_select_or_activate != 0 { self.update(with: .noMenuInteractions) }
		if ops.still_off != 0 { self.update(with: .noStillSkip) }
		if ops.pause_on != 0 { self.update(with: .noPause) }
		if ops.audio_stream_change != 0 { self.update(with: .noChangeAudioStream) }
		if ops.subpic_stream_change != 0 { self.update(with: .noChangeSubpictureStream) }
		if ops.angle_change != 0 { self.update(with: .noChangeViewingAngle) }
		if ops.karaoke_audio_pres_mode_change != 0 { self.update(with: .noChangeKaraokeMode) }
		if ops.video_pres_mode_change != 0 { self.update(with: .noChangeVideoMode) }
	}
}


/* MARK: Helper Extensions */

private extension String {
	/// Create a `String` from two ASCII characters in a two byte integer.
	init(twoCharacters combined: UInt16) {
		self.init()
		let unicodePoint0 = Unicode.Scalar(UInt8(combined.bits(8...15)))
		let unicodePoint1 = Unicode.Scalar(UInt8(combined.bits(0...7)))
		self.append(Character(unicodePoint0))
		self.append(Character(unicodePoint1))
	}
}

extension pgci_lu_t: Hashable {
	public func hash(into hasher: inout Hasher) {
		withUnsafeBytes(of: self) {
			hasher.combine(bytes: $0)
		}
	}
	public static func == (lhs: pgci_lu_t, rhs: pgci_lu_t) -> Bool {
		withUnsafeBytes(of: lhs) { lhs in
			withUnsafeBytes(of: rhs) { rhs in
				lhs.elementsEqual(rhs)
			}
		}
	}
}
