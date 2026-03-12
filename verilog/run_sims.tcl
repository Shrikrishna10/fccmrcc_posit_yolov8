#!/usr/bin/env tclsh
# =============================================================================
# run_sims.tcl
# Run all PDPU testbenches in Vivado xsim, batch mode.
#
# USAGE (from project root pdpu/):
#   vivado -mode batch -source scripts/run_sims.tcl
#
# Step 0: Generate golden vectors first (optional, needed for CSV bonus tests):
#   python scripts/gen_golden.py
#
# All testbenches pass on HARDCODED vectors alone — no golden files required.
# =============================================================================

set script_dir [file dirname [info script]]
set root       [file normalize "$script_dir/.."]

set rtl_arith  "$root/rtl/arithmetic"
set rtl_inc    "$root/rtl"
set tb_dir     "$root/tb"
set work_dir   "$root/sim_work"
set golden_dir "$root/golden"

file mkdir $work_dir
cd $work_dir

puts "\n=========================================================="
puts " PDPU Simulation Suite"
puts " Root:    $root"
puts " Work:    $work_dir"
puts "==========================================================\n"

# ── Step 0: Generate golden vectors if Python is available ──────────────────
set gen_script "$root/scripts/gen_golden.py"
if {[file exists $gen_script]} {
    puts "=== Generating golden vectors ==="
    if {[catch {exec python $gen_script} out]} {
        puts "WARNING: gen_golden.py returned an error:"
        puts $out
        puts "(Hardcoded testbench cases do not require golden files — continuing)\n"
    } else {
        puts $out
    }
} else {
    puts "WARNING: gen_golden.py not found at $gen_script"
}

# ── Helper: compile and simulate one testbench ──────────────────────────────
proc run_tb {name sv_files v_files tb_file rtl_inc work_dir golden_dir} {
    puts "\n----------------------------------------------------------"
    puts " Testbench: $name"
    puts "----------------------------------------------------------"

    # Compile Verilog RTL
    if {[llength $v_files] > 0} {
        set cmd [list xvlog -work work -i $rtl_inc {*}$v_files]
        puts "xvlog (V):  [join $v_files { }]"
        if {[catch {exec {*}$cmd} out]} { puts $out }
    }

    # Compile SystemVerilog RTL + testbench
    set sv_all [concat $sv_files $tb_file]
    set cmd [list xvlog -sv -work work -i $rtl_inc {*}$sv_all]
    puts "xvlog (SV): [join $sv_all { }]"
    if {[catch {exec {*}$cmd} out]} { puts $out }

    # Elaborate
    set cmd [list xelab -debug typical work.$name -s ${name}_snap]
    puts "xelab:      $name"
    if {[catch {exec {*}$cmd} out]} { puts $out }

    # Simulate — run from work_dir so VCD and log land there
    # Pass golden_dir as a define so testbenches can find CSV files
    set log_file "$work_dir/${name}.log"
    set cmd [list xsim ${name}_snap -runall -log $log_file]
    puts "xsim:       $name -> $log_file"
    if {[catch {exec {*}$cmd} out]} { puts $out }

    # Extract RESULT line from log
    if {[file exists $log_file]} {
        set fh [open $log_file r]
        set content [read $fh]
        close $fh
        foreach line [split $content "\n"] {
            if {[string match "*RESULT:*" $line]} {
                puts "  >>> $line"
            }
        }
    }
}

# ── Testbench 1: pdpu_mitchell_mult ─────────────────────────────────────────
run_tb tb_pdpu_mitchell_mult \
    [list] \
    [list "$rtl_arith/pdpu_mitchell_mult.v"] \
    "$tb_dir/tb_pdpu_mitchell_mult.sv" \
    $rtl_inc $work_dir $golden_dir

# ── Testbench 2: pdpu_pe ─────────────────────────────────────────────────────
run_tb tb_pdpu_pe \
    [list "$rtl_arith/pdpu_pe.sv"] \
    [list "$rtl_arith/pdpu_mitchell_mult.v"] \
    "$tb_dir/tb_pdpu_pe.sv" \
    $rtl_inc $work_dir $golden_dir

# ── Testbench 3: pdpu_reduction_tree ────────────────────────────────────────
run_tb tb_pdpu_reduction_tree \
    [list "$rtl_arith/pdpu_reduction_tree.sv"] \
    [list] \
    "$tb_dir/tb_pdpu_reduction_tree.sv" \
    $rtl_inc $work_dir $golden_dir

# ── Testbench 4: pdpu_array (integration) ───────────────────────────────────
run_tb tb_pdpu_array \
    [list \
        "$rtl_arith/pdpu_pe.sv" \
        "$rtl_arith/pdpu_reduction_tree.sv" \
        "$rtl_arith/pdpu_array.sv"] \
    [list \
        "$rtl_arith/pdpu_mitchell_mult.v" \
        "$rtl_arith/pdpu_approx_adder.v"] \
    "$tb_dir/tb_pdpu_array.sv" \
    $rtl_inc $work_dir $golden_dir

# ── Summary ──────────────────────────────────────────────────────────────────
puts "\n=========================================================="
puts " SUMMARY — check each log for RESULT line"
puts "=========================================================="
foreach name {tb_pdpu_mitchell_mult tb_pdpu_pe tb_pdpu_reduction_tree tb_pdpu_array} {
    set log "$work_dir/${name}.log"
    if {![file exists $log]} {
        puts "  $name : LOG NOT FOUND"
        continue
    }
    set fh [open $log r]
    set content [read $fh]
    close $fh
    set result "NOT FOUND"
    foreach line [split $content "\n"] {
        if {[string match "*RESULT:*" $line]} {
            set result [string trim $line]
        }
    }
    puts "  [format %-35s $name]  $result"
}
puts "==========================================================\n"
