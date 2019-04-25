#! /usr/bin/env ruby

require 'rubygems'
require 'bundler/setup'
require 'securerandom'
require 'ckb'

ALWAYS_SUCCESS = "0x0000000000000000000000000000000000000000000000000000000000000001".freeze

class BlockTime
  attr_accessor :timestamp, :number

  def initialize(timestamp:, number:)
    @timestamp = timestamp
    @number = number
  end

  def to_s
    "block #{number} #{timestamp}"
  end
end

class TxTask
  attr_accessor :tx_hash, :send_at, :proposed_at, :committed_at

  def initialize(tx_hash:, send_at:, proposed_at: nil, committed_at: nil)
    @tx_hash = tx_hash
    @send_at = send_at
    @proposed_at = proposed_at
    @committed_at = committed_at
  end

  def to_s
    "task #{tx_hash} send_at #{send_at} proposed_at #{proposed_at} committed_at #{committed_at}"
  end
end

class WatchPool
  def initialize(api, height)
    @api = api
    @height = height
    @initial = {}
    @short_id = {}
    @proposed = {}
    @committed = {}
  end

  def add(tx_hash, task)
    @initial[tx_hash] = task
    @short_id[tx_hash[0..22]] = tx_hash
  end

  def poll
    block_hash = @api.get_block_hash((@height + 1).to_s)
    puts "check block #{@height + 1} #{block_hash}"
    if block_hash.nil?
      return false
    end
    block = @api.get_block(block_hash)
    block_time = BlockTime.new(number: block[:number], timestamp: block[:timestamp])
    block[:proposal_transactions].each do |proposal_id|
      mark_proposed proposal_id, block_time
    end
    block[:commit_transactions].each do |tx|
      mark_committed tx[:hash], block_time
    end
    @height += 1
    true
  end

  def wait(tx_hash)
    loop do
      sleep 3 unless poll
      return if @committed.include? tx_hash
    end
  end

  def wait_all
    loop do
      sleep 3 unless poll
      return if @initial.empty? && @proposed.empty?
    end
  end

  private

  def mark_proposed proposal_id, block_time
    if (tx_hash = @short_id.delete proposal_id)
      tx_task = @initial.delete(tx_hash)
      raise "fuck, should not happen" if tx_task.nil?
      tx_task.proposed_at = block_time
      @proposed[tx_hash] = tx_task
      puts "tx #{tx_hash} get proposed at #{block_time}"
    end
  end

  def mark_committed tx_hash, block_time
    if (tx_task = @proposed.delete tx_hash)
      tx_task.committed_at = block_time
      @committed[tx_hash] = tx_task
      puts "tx #{tx_hash} get commited at #{block_time}"
    end
  end
end

def random_lock_id
  "0x" + SecureRandom.hex
end

def get_always_success_lock_hash(args: [])
  always_success_lock = {
    binary_hash: ALWAYS_SUCCESS,
    args: args
  }
  CKB::Utils.json_script_to_type_hash(always_success_lock)
end

def get_always_success_cellbase(api, from, to: from + 100)
  lock_hash = get_always_success_lock_hash
  api.get_cells_by_lock_hash(lock_hash, from.to_s, to.to_s).find {|c| c[:capacity] == 50000 }
end

def prepare_cells(api, from, count, lock_id: )
  cell = get_always_success_cellbase(api, from)
  if cell.nil?
    puts "can't find cellbase in #{from}"
    exit 1
  end
  puts "spend: #{cell}"
  inputs = [
    {
      previous_output: cell[:out_point],
      args: [],
      valid_since: "0",
    }
  ]

  if cell[:capacity] < count
    puts "txs too large, txs: #{count}, cellbase capacity: #{cell[:capacity]}"
    exit 1
  end

  per_output_cap = (cell[:capacity] / count).to_s
  outputs = count.times.map do |i|
    {
      capacity: per_output_cap,
      data: CKB::Utils.bin_to_hex("prepare_tx#{i}"),
      lock: {
        binary_hash: ALWAYS_SUCCESS,
        args: [lock_id]
      }
    }
  end

  # produce cells
  tip = api.get_tip_header
  tx = CKB::Transaction.new(
    version: 0,
    deps: [api.system_script_out_point],
    inputs: inputs,
    outputs: outputs
  )
  tx_hash = api.send_transaction(tx.to_h)
  TxTask.new(tx_hash: tx_hash, send_at: BlockTime.new(number: tip[:number].to_i, timestamp: tip[:timestamp].to_i))
end

def send_txs(prepare_tx_hash, txs_count, lock_id: )
  txs = txs_count.times.map do |i|
    inputs = [
      {
        previous_output: {hash: prepare_tx_hash, index: i},
        args: [],
        valid_since: "0"
      }
    ]
    outputs = [
      {
        capacity: cell[:capacity].to_s,
        data: CKB::Utils.bin_to_hex("tx#{i}"),
        lock: {
          binary_hash: ALWAYS_SUCCESS,
          args: [lock_id]
        }
      }
    ]

    CKB::Transaction.new(
      version: 0,
      deps: [api.system_script_out_point],
      inputs: inputs,
      outputs: outputs,
    )
  end
  tip = api.get_tip_header
  block_time = BlockTime.new(number: tip[:number].to_i, timestamp: tip[:timestamp].to_i)
  # sending
  tx_tasks = []
  txs.each_with_index do |tx, i|
    puts "sending tx #{i}/#{txs.size} ..."
    begin
      tx_hash = api.send_transaction(tx.to_h)
      tx_tasks << TxTask.new(tx_hash: tx_hash, send_at: block_time)
    rescue StandardError => e
      p e
    end
  end
  puts "send all transactions #{tx_tasks.size}/#{txs.size}"
  tx_tasks
end

def statistics(tx_tasks)
  puts "Total: #{tx_tasks.len}"
end

def run(api, from, txs_count)
  tip = api.get_tip_header
  watch_pool = WatchPool.new(api, tip[:number].to_i)
  lock_id = random_lock_id
  puts "generate random lock_id: #{lock_id}"
  puts "prepare #{txs_count} benchmark cells from height #{from}"
  tx_task = prepare_cells(api, from, txs_count, lock_id: lock_id)
  watch_pool.add(tx_task.tx_hash, tx_task)
  puts "wait prepare tx get confirmed ..."
  puts tx_task
  watch_pool.wait(tx_task.tx_hash)
  puts "start sending #{txs_count} txs..."
  tx_tasks = send_txs(api, from, txs_count, lock_id: lock_id)
  tx_tasks.each do |task|
    watch_pool.add task
  end
  puts "wait all txs get confirmed ..."
  tx_tasks.wait_all
  puts "complete, saving ..."
  Marshal.dump(tx_tasks, open("tx_records", "w+"))
  puts "statistis ..."
  statistics(tx_tasks)
end

if __FILE__ == $0
  api = CKB::API.new
  from, txs_count = ARGV[0].to_i, ARGV[1].to_i
  run(api, from, txs_count)
end
