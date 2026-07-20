# frozen_string_literal: true

require_relative '../spec_helper'

RSpec.describe Doom::Net::Lockstep do
  let(:ids) { [0, 1] }
  subject(:step) { described_class.new(local_id: 0, player_ids: ids, delay: 2) }

  def cmd(forward = 1.0)
    Doom::Game::Ticcmd.new(forward, 0.0, 0.0, 0)
  end

  describe 'construction' do
    it 'rejects a local id that is not a player' do
      expect { described_class.new(local_id: 9, player_ids: ids) }.to raise_error(ArgumentError)
    end

    it 'rejects a delay below one' do
      expect { described_class.new(local_id: 0, player_ids: ids, delay: 0) }.to raise_error(ArgumentError)
    end

    it 'starts ready, so play begins without waiting for a round trip' do
      expect(step).to be_ready
      expect(step.run_tic).to eq(1)
    end

    it 'primes exactly the delay worth of tics' do
      2.times { expect(step.take_cmds).not_to be_nil }
      expect(step.take_cmds).to be_nil  # tic 3 needs real input
    end

    it 'primes them with neutral commands' do
      cmds = step.take_cmds
      expect(cmds.keys).to match_array(ids)
      expect(cmds.values.map(&:forwardmove)).to all(eq(0.0))
    end
  end

  describe 'scheduling local input' do
    it 'schedules ahead by the delay' do
      expect(step.submit_local(cmd)).to eq(3)
      expect(step.submit_local(cmd)).to eq(4)
    end

    it 'does not let local input alone advance the simulation' do
      5.times { step.submit_local(cmd) }
      2.times { step.take_cmds }  # the primed tics

      expect(step).not_to be_ready
      expect(step.waiting_on).to eq([1])
    end
  end

  describe 'running tics' do
    it 'runs once every player has spoken' do
      2.times { step.take_cmds }
      step.submit_local(cmd)
      step.receive(3, 1, cmd(-1.0))

      expect(step).to be_ready
      cmds = step.take_cmds
      expect(cmds[0].forwardmove).to eq(1.0)
      expect(cmds[1].forwardmove).to eq(-1.0)
    end

    it 'stalls rather than guessing a missing command' do
      2.times { step.take_cmds }
      step.submit_local(cmd)

      expect(step).to be_stalled
      expect(step.take_cmds).to be_nil
      expect(step.run_tic).to eq(3)  # did not advance
    end

    it 'resumes exactly where it stalled once the command arrives' do
      2.times { step.take_cmds }
      3.times { step.submit_local(cmd) }
      step.receive(4, 1, cmd)
      step.receive(5, 1, cmd)

      expect(step).to be_stalled  # tic 3 still missing

      step.receive(3, 1, cmd)
      expect(step.take_cmds).not_to be_nil
      expect(step.take_cmds).not_to be_nil
      expect(step.take_cmds).not_to be_nil
      expect(step.run_tic).to eq(6)
    end
  end

  describe 'unreliable delivery' do
    it 'ignores a duplicate, keeping the command a tic was decided with' do
      2.times { step.take_cmds }
      step.submit_local(cmd)
      step.receive(3, 1, cmd(-1.0))
      step.receive(3, 1, cmd(0.5))  # a resend arriving late

      expect(step.take_cmds[1].forwardmove).to eq(-1.0)
    end

    it 'drops commands for tics already simulated' do
      2.times { step.take_cmds }
      step.submit_local(cmd)
      step.receive(3, 1, cmd)
      step.take_cmds

      expect(step.receive(3, 1, cmd)).to be false
    end

    it 'ignores commands from an unknown player' do
      expect(step.receive(3, 99, cmd)).to be false
    end

    it 'accepts commands that arrive out of order' do
      2.times { step.take_cmds }
      3.times { step.submit_local(cmd) }
      step.receive(5, 1, cmd)
      step.receive(3, 1, cmd)
      step.receive(4, 1, cmd)

      expect(3.times.map { step.take_cmds }.compact.size).to eq(3)
    end

    it 'offers recent local commands for the transport to resend' do
      4.times { step.submit_local(cmd) }
      recent = step.recent_local(3)

      expect(recent.map(&:first)).to eq([4, 5, 6])
      expect(recent.last.last).to be_a(Doom::Game::Ticcmd)
    end

    describe '#local_since' do
      it 'resends from where the peer says it is stuck' do
        6.times { step.submit_local(cmd) }  # tics 3..8
        expect(step.local_since(5, 10).map(&:first)).to eq([5, 6, 7, 8])
      end

      it 'bounds how many it returns' do
        20.times { step.submit_local(cmd) }
        expect(step.local_since(3, 4).map(&:first)).to eq([3, 4, 5, 6])
      end

      it 'sends everything when the peer is at zero' do
        3.times { step.submit_local(cmd) }
        expect(step.local_since(0, 10).map(&:first)).to eq([3, 4, 5])
      end

      it 'falls back to the newest commands when the peer is ahead of us' do
        # Nothing to resend, but a packet still has to carry something useful.
        3.times { step.submit_local(cmd) }
        expect(step.local_since(999, 2).map(&:first)).to eq([4, 5])
      end

      it 'is empty before anything has been sent' do
        expect(step.local_since(0, 5)).to eq([])
      end
    end

    it 'reports the tic it is waiting for as its ack' do
      expect(step.ack_tic).to eq(1)
      2.times { step.take_cmds }
      expect(step.ack_tic).to eq(3)
    end

    it 'keeps sent commands after the local tic passes them' do
      # A peer that lost a packet is stalled on a tic we already ran; resending
      # it is the only thing that frees them.
      2.times { step.take_cmds }
      step.submit_local(cmd)
      step.receive(3, 1, cmd)
      step.take_cmds

      expect(step.recent_local(5).map(&:first)).to include(3)
    end
  end

  # A peer that opens a menu, hits a long GC pause or briefly loses its link
  # stops acknowledging. Everything it has not acknowledged has to survive, or
  # it comes back to find the commands it needs no longer exist anywhere and
  # waits on them forever.
  describe 'a peer that goes away and comes back' do
    def play_round(a, b)
      a.submit_local(cmd)
      b.submit_local(cmd)
      deliver(a, b)
      deliver(b, a)
      while a.take_cmds; end
      while b.take_cmds; end
    end

    def deliver(from, to)
      from.local_since(to.ack_tic, 8).each { |tic, c| to.receive(tic, from.local_id, c) }
      from.note_ack(to.local_id, to.ack_tic)
    end

    let(:a) { described_class.new(local_id: 0, player_ids: ids, delay: 2) }
    let(:b) { described_class.new(local_id: 1, player_ids: ids, delay: 2) }

    def pause_and_resume(pause_tics)
      20.times { play_round(a, b) }

      # b is away: it neither sends nor receives, and stops acknowledging.
      pause_tics.times do
        a.submit_local(cmd)
        while a.take_cmds; end
      end

      before = b.run_tic
      300.times { play_round(a, b) }
      [before, b.run_tic]
    end

    it 'recovers from a short absence' do
      before, after = pause_and_resume(20)
      expect(after).to be > before
    end

    it 'recovers from an absence longer than a fixed resend window' do
      # This is the regression: with the old fixed 64-tic history, a pause of
      # about two seconds wedged the session permanently.
      before, after = pause_and_resume(200)
      expect(after).to be > before
    end

    it 'catches the absent peer all the way up' do
      pause_and_resume(200)
      expect(b.run_tic).to eq(a.run_tic)
    end

    it 'keeps the commands an unacknowledged peer still needs' do
      20.times { play_round(a, b) }
      stuck_at = b.ack_tic
      300.times { a.submit_local(cmd) }

      expect(a.local_since(stuck_at, 1).first&.first).to eq(stuck_at)
    end
  end

  describe 'memory' do
    it 'bounds the local history when no peer ever acknowledges' do
      # Backstop for a peer that is never coming back.
      (described_class::LOCAL_HISTORY + 500).times { step.submit_local(cmd) }
      sent = step.instance_variable_get(:@local_sent)
      expect(sent.size).to be <= described_class::LOCAL_HISTORY
    end

    it 'drops buffered tics once simulated' do
      2.times { step.take_cmds }
      200.times do |i|
        step.submit_local(cmd)
        step.receive(3 + i, 1, cmd)
        step.take_cmds
      end
      expect(step.instance_variable_get(:@buffer).size).to be < 10
    end
  end

  describe 'driving a world' do
    before(:all) do
      skip_without_wad
      @wad = Doom::Wad::Reader.new(wad_path)
      @sprites = Doom::Wad::SpriteManager.new(@wad)
    end

    after(:all) { @wad&.close }

    def new_world(seed = 0)
      map = Doom::Map::MapData.load(@wad, 'E1M1')
      w = Doom::Game::World.new(map, sprites: @sprites, random: Doom::Game::Random.new(seed))
      w.add_player(id: 0)
      w.add_player(id: 1)
      w
    end

    it 'runs only the tics it has commands for' do
      w = new_world
      2.times { step.submit_local(cmd) }
      step.receive(3, 1, cmd)

      expect(step.run_ready(w)).to eq(3)  # two primed tics plus tic 3
      expect(w.leveltime).to eq(3)
    end

    it 'stops at the gap and continues from it' do
      w = new_world
      3.times { step.submit_local(cmd) }
      step.receive(4, 1, cmd)  # tic 3 missing

      expect(step.run_ready(w)).to eq(2)
      step.receive(3, 1, cmd)
      expect(step.run_ready(w)).to eq(2)
      expect(w.leveltime).to eq(4)
    end

    it 'respects the per-call limit so one slow catch-up cannot hang a frame' do
      w = new_world
      50.times { |i| step.submit_local(cmd); step.receive(3 + i, 1, cmd) }
      expect(step.run_ready(w, limit: 5)).to eq(5)
    end

    # The property the whole design exists for.
    it 'keeps two independently driven worlds identical' do
      a_world = new_world(11)
      b_world = new_world(11)
      a = described_class.new(local_id: 0, player_ids: ids, delay: 2)
      b = described_class.new(local_id: 1, player_ids: ids, delay: 2)

      120.times do |i|
        a_cmd = Doom::Game::Ticcmd.new(1.0, 0.0, (i % 5) - 2.0, 0)
        b_cmd = Doom::Game::Ticcmd.new(-1.0, 1.0, 0.0, (i % 3).zero? ? Doom::Game::Ticcmd::BTN_FIRE : 0)

        a_tic = a.submit_local(a_cmd)
        b_tic = b.submit_local(b_cmd)
        # Cross-deliver, as a transport would.
        b.receive(a_tic, 0, a_cmd)
        a.receive(b_tic, 1, b_cmd)

        a.run_ready(a_world)
        b.run_ready(b_world)
      end

      expect(a_world.leveltime).to eq(b_world.leveltime)
      expect(a_world.state_hash).to eq(b_world.state_hash)
    end
  end
end
