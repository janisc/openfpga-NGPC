"""Upstream bridge regression plus explicit cart codec error propagation."""
from pathlib import Path
import subprocess,json
ROOT=Path(__file__).resolve().parents[1];dev=ROOT;out=ROOT/'dist/savefix-tests/bridge';out.mkdir(parents=True,exist_ok=True)
s=(dev/'sim/tb_savestate_bridge.sv').read_text()
s=s.replace('module tb;', 'module tb;\n reg mock_save_error=0,mock_load_error=0;')
s=s.replace('.cart_save_done  (cart_save_done),','.cart_save_done  (cart_save_done),\n        .cart_save_error(mock_save_error),')
s=s.replace('.cart_load_done  (cart_load_done),','.cart_load_done  (cart_load_done),\n        .cart_load_error(mock_load_error),')
extra=r'''
        begin : codec_failures
            integer ok;
            $display("== S8 cart overflow reports save error");
            machine_init;mock_save_error=1;apf_save(0);
            if(!start_err || start_ok)$fatal(1,"cart save failure hidden");
            mock_save_error=0;
            $display("   PASS (save error propagated)");
            $display("== S9 cart validation failure prevents machine restore");
            machine_init;apf_save(0);machine_corrupt;
            apf_write_burst(1,8,-1,0,0);mock_load_error=1;apf_load(ok);
            if(ok || internals[0]!==64'hDEADBEEF_DEADBEEF || mem0[0]!==8'hFF)
                $fatal(1,"cart rejection hidden or machine restore started");
            mock_load_error=0;
            $display("   PASS (load error propagated, machine untouched)");
        end
'''
s=s.replace('\t\tif (errors == 0) $display("== ALL SCENARIOS MATCHED EXPECTATIONS");',extra+'\n\t\tif (errors != 0) $fatal(1,"bridge regression failure");\n\t\tif (errors == 0) $display("== ALL SCENARIOS MATCHED EXPECTATIONS");')
s=s.replace('$display("== WATCHDOG TIMEOUT");','$fatal(1,"WATCHDOG TIMEOUT");')
tb=out/'tb.sv';tb.write_text(s)
cmd=['iverilog','-g2012','-DSYNTHESIS','-s','tb','-o',str(out/'test.vvp'),str(ROOT/'upstream/rtl/Savestates/savestates.sv'),str(dev/'target/pocket/ngpc_savestate_bridge.sv'),str(dev/'sim/sim_synch3.v'),str(tb)]
c=subprocess.run(cmd,capture_output=True,text=True,cwd=ROOT);(out/'compile.log').write_text(c.stdout+c.stderr);assert c.returncode==0,c.stderr
with (out/'simulation.log').open('w') as log:
 v=subprocess.run(['vvp','-i',str(out/'test.vvp')],stdout=log,stderr=subprocess.STDOUT,cwd=ROOT,timeout=180)
output=(out/'simulation.log').read_text();print(output);assert v.returncode==0
(out/'result.json').write_text(json.dumps(dict(result='PASS',output=output,limitations='Actual bridge and upstream state engine, modeled cart copier and APF host. Codec failures injected at bridge interface.'),indent=2)+'\n')
