import Foundation

/// The portal's component CSS and behavior JS, split out so ``RemotePortalPage``
/// stays readable. Both are static, theme-agnostic (they consume the CSS
/// variables from ``RemoteRouter/themeCSS``), and wired to the JSON API by cookie
/// (no embedded secret). Everything here is inert markup/script text.
enum RemotePortalAssets {

    static let css = #"""
    *{box-sizing:border-box;margin:0;padding:0}
    html,body{height:100%;font-family:-apple-system,BlinkMacSystemFont,"SF Pro Text","Helvetica Neue",system-ui,sans-serif;-webkit-font-smoothing:antialiased}
    body{background:var(--bg-app);color:var(--text);overflow:hidden;display:flex;flex-direction:column;height:100vh}
    button,input,select,textarea{font:inherit;color:inherit}
    svg{display:block}
    ::-webkit-scrollbar{width:10px;height:10px}::-webkit-scrollbar-thumb{background:var(--border-strong);border-radius:6px;border:2px solid transparent;background-clip:padding-box}
    /* topbar */
    .topbar{height:54px;flex:0 0 54px;display:flex;align-items:center;gap:12px;padding:0 14px;background:var(--bg-bar);backdrop-filter:blur(30px) saturate(160%);-webkit-backdrop-filter:blur(30px) saturate(160%);border-bottom:1px solid var(--border);z-index:40}
    .brand{display:flex;align-items:center;gap:10px;font-weight:700;font-size:15px}
    .brand .mk{width:28px;height:28px;border-radius:8px;overflow:hidden;box-shadow:0 3px 8px rgba(0,0,0,.3)}
    .brand .mk svg{width:100%;height:100%}
    .brand .sub{font-size:10px;font-weight:600;color:var(--text-faint);background:var(--bg-chip);padding:2px 6px;border-radius:5px}
    .hamburger{display:none;width:36px;height:36px;border:0;background:var(--bg-control);border-radius:9px;color:var(--text);cursor:pointer;place-items:center}
    .hamburger svg{width:18px;height:18px}
    .search{flex:1;max-width:340px;display:flex;align-items:center;gap:8px;background:var(--bg-input);border:1px solid var(--border);border-radius:9px;padding:0 10px;height:34px}
    .search svg{width:15px;height:15px;color:var(--text-faint);flex:0 0 auto}.search input{flex:1;background:none;border:0;outline:none;font-size:13px}
    .spacer{flex:1}
    .stats{display:flex;gap:12px;font-size:12.5px;font-variant-numeric:tabular-nums}
    .stat{display:flex;align-items:center;gap:5px}.stat svg{width:13px;height:13px}.stat.down{color:var(--green)}.stat.up{color:var(--teal)}.stat b{font-weight:600}
    .ico{width:36px;height:36px;border:0;background:var(--bg-control);border-radius:9px;color:var(--text-dim);cursor:pointer;display:grid;place-items:center}
    .ico:hover{background:var(--bg-control-active);color:var(--text)}.ico.active{background:var(--accent);color:#fff}.ico svg{width:17px;height:17px}
    .add-btn{height:36px;padding:0 14px;border:0;border-radius:9px;background:var(--accent);color:#fff;font-size:13px;font-weight:600;cursor:pointer;display:inline-flex;align-items:center;gap:7px}
    .add-btn:hover{background:var(--accent-press)}.add-btn svg{width:15px;height:15px}
    .user{display:flex;align-items:center;gap:8px;height:36px;padding:0 6px 0 8px;border:0;background:var(--bg-control);border-radius:20px;color:var(--text);cursor:pointer}
    .user:hover{background:var(--bg-control-active)}.avatar{width:26px;height:26px;border-radius:50%;background:linear-gradient(145deg,#5db4f5,#2f83e6);display:grid;place-items:center;color:#fff;font-size:12px;font-weight:700}
    .user .uname{font-size:12.5px;font-weight:600}.user svg{width:13px;height:13px;color:var(--text-dim)}
    /* shell */
    .shell{flex:1;display:flex;min-height:0;position:relative}
    .sidebar{width:214px;flex:0 0 214px;background:var(--bg-sidebar);backdrop-filter:blur(30px);-webkit-backdrop-filter:blur(30px);border-right:1px solid var(--border);padding:12px 10px;overflow-y:auto;display:flex;flex-direction:column;gap:2px;z-index:30}
    .s-lbl{font-size:10.5px;font-weight:700;letter-spacing:.6px;text-transform:uppercase;color:var(--text-faint);padding:13px 8px 5px}.s-lbl:first-child{padding-top:2px}
    .s-item{display:flex;align-items:center;gap:10px;padding:7px 9px;border-radius:8px;cursor:pointer;font-size:13px;color:var(--text)}
    .s-item:hover{background:var(--bg-row-hover)}.s-item.active{background:var(--accent);color:#fff}.s-item.active .ct{background:rgba(255,255,255,.25);color:#fff}
    .s-item svg{width:16px;height:16px;opacity:.85;flex:0 0 auto}.s-item .l{flex:1;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
    .ct{font-size:11px;font-weight:600;min-width:20px;text-align:center;padding:1px 6px;border-radius:9px;background:var(--bg-chip);color:var(--text-dim)}
    .sb-backdrop{display:none}
    .content{flex:1;display:flex;flex-direction:column;min-width:0;background:var(--bg-content)}
    .view{flex:1;display:flex;flex-direction:column;min-height:0}.view[hidden]{display:none}
    .ro-banner{background:var(--red-soft);color:var(--red);font-size:12px;padding:8px 16px;text-align:center;border-bottom:1px solid var(--border)}
    .lhead{display:grid;grid-template-columns:1fr 96px 150px 108px;align-items:center;height:34px;flex:0 0 34px;padding:0 16px;border-bottom:1px solid var(--border);font-size:11px;font-weight:600;color:var(--text-dim)}
    .lhead>div{padding:0 6px}.lhead .r{text-align:right}
    .rows{flex:1;overflow-y:auto}
    .row{display:grid;grid-template-columns:1fr 96px 150px 108px;align-items:center;min-height:56px;padding:0 16px;border-bottom:1px solid var(--border);cursor:pointer}
    .row:nth-child(even){background:var(--bg-row-alt)}.row:hover{background:var(--bg-row-hover)}.row.sel{background:var(--bg-row-sel)}
    .row .c{padding:0 6px;font-size:12.5px;min-width:0}.c.r{text-align:right;font-variant-numeric:tabular-nums;color:var(--text-dim)}.c.dspd{color:var(--green);font-weight:500}
    .ncell{display:flex;align-items:center;gap:11px;min-width:0}
    .sbtn{width:28px;height:28px;flex:0 0 28px;border-radius:50%;border:0;cursor:pointer;display:grid;place-items:center;background:var(--bg-control);color:var(--text-dim)}
    .sbtn:hover{background:var(--accent);color:#fff}.sbtn svg{width:13px;height:13px}
    .ftype{width:32px;height:32px;flex:0 0 32px;border-radius:8px;display:grid;place-items:center;color:#fff}.ftype svg{width:17px;height:17px}
    .ft-iso{background:linear-gradient(145deg,#ff9f0a,#ff6a00)}.ft-video{background:linear-gradient(145deg,#bf5af2,#8a3ffc)}.ft-archive{background:linear-gradient(145deg,#64d2ff,#0a84ff)}.ft-app{background:linear-gradient(145deg,#32d74b,#1a9e3a)}.ft-magnet{background:linear-gradient(145deg,#ff453a,#c91d12)}.ft-doc{background:linear-gradient(145deg,#8e8e93,#636366)}
    .nmeta{min-width:0;display:flex;flex-direction:column;gap:4px}.nline{display:flex;align-items:center;gap:8px;min-width:0}
    .ntext{font-size:12.5px;font-weight:500;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
    .kb{font-size:9px;font-weight:700;padding:1px 5px;border-radius:4px;letter-spacing:.3px;flex:0 0 auto}
    .kb-http{background:rgba(100,210,255,.18);color:var(--teal)}.kb-torrent{background:rgba(191,90,242,.2);color:var(--purple)}.kb-ftp{background:rgba(255,159,10,.18);color:var(--orange)}.kb-sftp{background:rgba(50,215,75,.16);color:var(--green)}.kb-hls{background:rgba(255,69,58,.16);color:var(--red)}
    .mp{height:4px;border-radius:3px;background:var(--seg-empty);overflow:hidden;width:100%;max-width:440px}.mp>i{display:block;height:100%;border-radius:3px;background:var(--accent);transition:width .5s}
    .mp.seeding>i,.mp.completed>i{background:var(--green)}.mp.paused>i{background:var(--text-faint)}.mp.failed>i{background:var(--red)}
    .mp.metadata>i{background:linear-gradient(90deg,transparent,var(--orange),transparent);background-size:200% 100%;animation:sh 1.4s linear infinite}
    @keyframes sh{from{background-position:200% 0}to{background-position:-200% 0}}
    .scell{display:flex;align-items:center;gap:6px}.sdot{width:7px;height:7px;border-radius:50%;flex:0 0 7px}
    .st-downloading,.st-verifying{background:var(--accent);box-shadow:0 0 6px var(--accent);animation:pl 1.6s ease-in-out infinite}.st-seeding{background:var(--green);box-shadow:0 0 6px var(--green)}.st-completed{background:var(--green)}.st-paused,.st-queued{background:var(--text-faint)}.st-failed{background:var(--red)}.st-metadata{background:var(--orange);animation:pl 1.1s infinite}
    @keyframes pl{0%,100%{opacity:1}50%{opacity:.35}}
    .stext{font-size:11.5px;color:var(--text-dim);white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
    .empty{display:grid;place-items:center;height:100%;text-align:center;color:var(--text-faint);padding:30px}.empty svg{width:46px;height:46px;opacity:.3;margin-bottom:12px}.empty h4{font-size:14px;color:var(--text-dim);margin-bottom:5px}.empty p{font-size:12px;line-height:1.5;max-width:280px}
    /* detail */
    .detail{width:360px;flex:0 0 360px;background:var(--bg-panel);backdrop-filter:blur(34px) saturate(160%);-webkit-backdrop-filter:blur(34px) saturate(160%);border-left:1px solid var(--border);display:flex;flex-direction:column;min-height:0;transition:margin-right .3s cubic-bezier(.3,.9,.3,1),opacity .25s;z-index:35}
    .detail.hidden{margin-right:-361px;opacity:0;pointer-events:none}
    .dhead{padding:16px 16px 12px;border-bottom:1px solid var(--border)}
    .dtop{display:flex;align-items:center;gap:11px}.dtop .ftype{width:40px;height:40px;flex-basis:40px;border-radius:10px}.dtop .ftype svg{width:21px;height:21px}
    .dname{font-size:14px;font-weight:600;line-height:1.3;word-break:break-word}.dsub{font-size:11.5px;color:var(--text-dim);margin-top:2px}
    .dx{margin-left:auto;width:28px;height:28px;border:0;background:var(--bg-control);border-radius:8px;color:var(--text-dim);cursor:pointer;display:grid;place-items:center;flex:0 0 28px}.dx:hover{background:var(--red);color:#fff}.dx svg{width:14px;height:14px}
    .dact{display:flex;gap:7px;margin-top:12px;flex-wrap:wrap}
    .mbtn{height:30px;padding:0 11px;border:0;border-radius:8px;background:var(--bg-control);color:var(--text);font-size:12px;font-weight:500;cursor:pointer;display:inline-flex;align-items:center;gap:6px}
    .mbtn:hover{background:var(--bg-control-active)}.mbtn.accent{background:var(--accent);color:#fff}.mbtn.accent:hover{background:var(--accent-press)}.mbtn.danger:hover{background:var(--red);color:#fff}.mbtn svg{width:13px;height:13px}
    .tabs{display:flex;gap:1px;padding:9px 12px 0;border-bottom:1px solid var(--border);overflow-x:auto}
    .tab{flex:1;min-width:62px;text-align:center;padding:8px 4px 10px;font-size:11.5px;font-weight:500;color:var(--text-dim);cursor:pointer;border-bottom:2px solid transparent;white-space:nowrap}
    .tab:hover{color:var(--text)}.tab.active{color:var(--accent);border-bottom-color:var(--accent)}
    .tbody{flex:1;overflow-y:auto;padding:14px 16px 20px}
    .kv{display:flex;justify-content:space-between;gap:12px;padding:8px 0;border-bottom:1px solid var(--border);font-size:12px}.kv:last-child{border-bottom:0}
    .kv .k{color:var(--text-dim);flex:0 0 auto}.kv .v{color:var(--text);text-align:right;word-break:break-word;font-variant-numeric:tabular-nums;display:flex;align-items:center;gap:6px;justify-content:flex-end;min-width:0}
    .kv .v .ell{overflow:hidden;text-overflow:ellipsis;white-space:nowrap;max-width:200px}
    .cbtn{width:19px;height:19px;border-radius:5px;border:0;background:var(--bg-control);color:var(--text-dim);cursor:pointer;display:grid;place-items:center;flex:0 0 auto}.cbtn:hover{background:var(--accent);color:#fff}.cbtn svg{width:10px;height:10px}
    .dpw{margin:6px 0 14px}.dptop{display:flex;align-items:baseline;justify-content:space-between;margin-bottom:8px}.dpct{font-size:24px;font-weight:700;font-variant-numeric:tabular-nums}.dpsz{font-size:11.5px;color:var(--text-dim)}
    .dpbar{height:8px;border-radius:5px;background:var(--seg-empty);overflow:hidden}.dpbar>i{display:block;height:100%;background:var(--accent);border-radius:5px;transition:width .5s}
    .slbl{font-size:10.5px;font-weight:700;letter-spacing:.5px;text-transform:uppercase;color:var(--text-faint);margin:16px 0 8px}
    .pieces{display:grid;grid-template-columns:repeat(auto-fill,13px);gap:3px}.pieces>span{width:13px;height:13px;border-radius:3px;background:var(--seg-empty)}.pieces>span.f{background:var(--green)}.pieces>span.p{background:var(--accent)}
    .frow{display:flex;align-items:center;gap:10px;padding:9px 0;border-bottom:1px solid var(--border);font-size:12px}.frow:last-child{border-bottom:0}
    .fchk{width:17px;height:17px;border-radius:5px;border:1.5px solid var(--border-strong);cursor:pointer;flex:0 0 17px;display:grid;place-items:center}.fchk.on{background:var(--accent);border-color:var(--accent)}.fchk svg{width:10px;height:10px;color:#fff;opacity:0}.fchk.on svg{opacity:1}
    .finfo{flex:1;min-width:0}.fname{white-space:nowrap;overflow:hidden;text-overflow:ellipsis}.fbar{height:3px;border-radius:2px;background:var(--seg-empty);margin-top:5px;overflow:hidden}.fbar>i{display:block;height:100%;background:var(--green)}
    .fsz{font-size:11px;color:var(--text-dim);flex:0 0 auto;font-variant-numeric:tabular-nums}
    .fprio{font-size:10px;padding:1px 7px;border-radius:6px;background:var(--bg-chip);color:var(--text-dim);flex:0 0 auto;cursor:pointer;text-transform:capitalize}.fprio.high{background:rgba(255,159,10,.2);color:var(--orange)}
    .crow{display:grid;grid-template-columns:1fr 60px 60px;gap:8px;padding:8px 0;border-bottom:1px solid var(--border);font-size:11.5px;align-items:center}.crow.h{color:var(--text-faint);font-weight:600;font-size:10.5px;text-transform:uppercase}
    .cip{white-space:nowrap;overflow:hidden;text-overflow:ellipsis;font-variant-numeric:tabular-nums}.cd{text-align:right;color:var(--green);font-variant-numeric:tabular-nums}.cu{text-align:right;color:var(--teal);font-variant-numeric:tabular-nums}
    /* statusbar */
    .statusbar{height:36px;flex:0 0 36px;display:flex;align-items:center;gap:12px;padding:0 14px;background:var(--bg-bar);border-top:1px solid var(--border);font-size:11.5px}.sb-dim{color:var(--text-faint)}.sp{flex:1}
    /* panes */
    .pad{padding:20px 22px;overflow-y:auto;flex:1}
    .ph{font-size:18px;font-weight:700;margin-bottom:4px}.psub{font-size:12.5px;color:var(--text-dim);margin-bottom:20px;line-height:1.5}
    .card{background:var(--bg-panel);border:1px solid var(--border);border-radius:14px;padding:6px 16px;margin-bottom:16px}.card.pd{padding:16px}
    .srow{display:flex;align-items:center;gap:16px;padding:13px 0;border-bottom:1px solid var(--border)}.srow:last-child{border-bottom:0}
    .sinfo{flex:1;min-width:0}.sname{font-size:13px;font-weight:500;display:flex;align-items:center;gap:8px}.sdesc{font-size:11.5px;color:var(--text-dim);margin-top:3px;line-height:1.45}
    .sctl{flex:0 0 auto;display:flex;align-items:center;gap:8px}
    .seg{display:flex;background:var(--bg-control);border-radius:9px;padding:3px;border:1px solid var(--border);flex-wrap:wrap;gap:2px}
    .seg button{border:0;background:none;color:var(--text-dim);font-size:12px;font-weight:500;padding:6px 12px;border-radius:7px;cursor:pointer;display:flex;align-items:center;gap:6px}
    .seg button.on{background:var(--accent);color:#fff}.seg .sw{width:11px;height:11px;border-radius:3px;flex:0 0 auto}
    .chip{display:inline-flex;align-items:center;gap:5px;font-size:10px;font-weight:600;padding:2px 7px;border-radius:6px}.chip-d{background:rgba(255,159,10,.16);color:var(--orange)}.chip-w{background:rgba(50,215,75,.16);color:var(--green)}
    .hrow{display:grid;grid-template-columns:32px 1fr 96px 150px auto;align-items:center;gap:10px;padding:11px 0;border-bottom:1px solid var(--border);font-size:12.5px}.hrow:last-child{border-bottom:0}
    .hic{width:28px;height:28px;border-radius:7px;display:grid;place-items:center;color:#fff}
    /* modal */
    .scrim{position:fixed;inset:0;z-index:120;background:var(--scrim);backdrop-filter:blur(3px);display:none;align-items:center;justify-content:center;padding:20px}.scrim.open{display:flex}
    .modal{width:560px;max-width:100%;max-height:88vh;background:var(--bg-modal);border-radius:16px;border:1px solid var(--border-strong);box-shadow:0 30px 80px rgba(0,0,0,.55);display:flex;flex-direction:column;overflow:hidden}
    .mhead{padding:18px 22px 14px;border-bottom:1px solid var(--border);display:flex;align-items:center;gap:12px}.mhead h3{font-size:15px;font-weight:600;flex:1}
    .mic{width:32px;height:32px;border-radius:9px;background:var(--accent);display:grid;place-items:center;color:#fff}.mic svg{width:17px;height:17px}
    .mbody{padding:20px 22px;overflow-y:auto}.mfoot{padding:14px 22px;border-top:1px solid var(--border);display:flex;gap:10px;justify-content:flex-end}
    .flabel{display:block;font-size:12px;font-weight:600;color:var(--text-dim);margin-bottom:6px}
    .finput{width:100%;background:var(--bg-input);border:1px solid var(--border);border-radius:10px;padding:10px 12px;font-size:13px;color:var(--text)}.finput:focus{outline:none;border-color:var(--accent)}
    textarea.finput{min-height:88px;font-family:inherit;resize:vertical}
    .fhint{font-size:11px;color:var(--text-faint);margin-top:6px;line-height:1.5}.fhint svg{width:12px;height:12px;display:inline;vertical-align:-2px;color:var(--orange)}
    .twocol{display:flex;gap:14px;margin-top:16px}.twocol .fg{flex:1}
    .btn{height:38px;padding:0 16px;border:0;border-radius:10px;background:var(--bg-control);color:var(--text);font-size:13px;font-weight:600;cursor:pointer}.btn:hover{background:var(--bg-control-active)}.btn.primary{background:var(--accent);color:#fff}.btn.primary:hover{background:var(--accent-press)}
    .menu{position:fixed;z-index:140;min-width:210px;background:var(--bg-modal);border:1px solid var(--border-strong);border-radius:11px;box-shadow:0 18px 50px rgba(0,0,0,.5);padding:5px;font-size:12.5px}
    .mi{display:flex;align-items:center;gap:10px;padding:7px 10px;border-radius:7px;cursor:pointer;color:var(--text);white-space:nowrap}.mi:hover{background:var(--accent);color:#fff}.mi:hover svg{color:#fff}.mi svg{width:15px;height:15px;color:var(--text-dim);flex:0 0 auto}.mi .t{flex:1}
    .mi.danger{color:var(--red)}.mi.danger svg{color:var(--red)}.mi.danger:hover{background:var(--red);color:#fff}.msep{height:1px;background:var(--border);margin:4px 6px}
    /* toasts */
    .toasts{position:fixed;bottom:52px;left:50%;transform:translateX(-50%);display:flex;flex-direction:column;gap:8px;z-index:160;align-items:center}
    .toast{display:flex;align-items:center;gap:9px;background:var(--bg-modal);border:1px solid var(--border-strong);border-radius:11px;box-shadow:0 12px 34px rgba(0,0,0,.4);padding:10px 15px;font-size:12.5px;animation:ti .28s;max-width:88vw}.toast svg{width:16px;height:16px;color:var(--accent);flex:0 0 auto}.toast.out{opacity:0;transition:.3s}
    @keyframes ti{from{opacity:0;transform:translateY(12px)}to{opacity:1}}
    /* responsive */
    @media(max-width:920px){.detail{position:absolute;right:0;top:0;bottom:0;box-shadow:-10px 0 40px rgba(0,0,0,.4)}.detail.hidden{transform:translateX(100%);margin-right:0}.lhead,.row{grid-template-columns:1fr 96px 108px}.lhead .hide-sm,.row .c.hide-sm{display:none}}
    @media(max-width:680px){.sidebar{position:absolute;left:0;top:0;bottom:0;transform:translateX(-100%);transition:transform .28s;box-shadow:10px 0 40px rgba(0,0,0,.4)}.sidebar.open{transform:none}.sb-backdrop.show{display:block;position:absolute;inset:0;background:rgba(0,0,0,.4);z-index:29}.hamburger{display:grid}.search,.stats,.user .uname,.brand .sub{display:none}.add-btn .lbl{display:none}.add-btn{padding:0 12px}.detail{width:100%;flex-basis:100%}.lhead,.row{grid-template-columns:1fr 96px}.lhead .hide-xs,.row .c.hide-xs{display:none}}
    """#

    static let js = #"""
    (function(){
    const $=s=>document.querySelector(s),$$=s=>[...document.querySelectorAll(s)];
    const THEMES=['frost-light','frost-dark','dracula','nord'];
    const THEME_LABEL={'frost-light':'Frost Light','frost-dark':'Frost Dark','dracula':'Dracula','nord':'Nord'};
    const THEME_ACCENT={'frost-light':'#3F58D6','frost-dark':'#8AA2FF','dracula':'#BD93F9','nord':'#88C0D0'};
    const S={view:'library',filter:'all',sel:null,tab:'general',tasks:[],detail:null,search:'',panel:innerWidth>920,write:!BOOT.readOnly};
    const ICON={
      play:'<svg viewBox="0 0 24 24" fill="currentColor"><path d="M8 5v14l11-7z"/></svg>',
      pause:'<svg viewBox="0 0 24 24" fill="currentColor"><path d="M7 5h3.5v14H7zM13.5 5H17v14h-3.5z"/></svg>',
      retry:'<svg viewBox="0 0 24 24" fill="none"><path d="M4 12a8 8 0 018-8c2.5 0 4.7 1.1 6.2 2.9M20 5v4h-4M20 12a8 8 0 01-8 8c-2.5 0-4.7-1.1-6.2-2.9M4 19v-4h4" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/></svg>',
      copy:'<svg viewBox="0 0 24 24" fill="none"><rect x="9" y="9" width="11" height="11" rx="2" stroke="currentColor" stroke-width="2"/><path d="M5 15V5a2 2 0 012-2h10" stroke="currentColor" stroke-width="2"/></svg>',
      check:'<svg viewBox="0 0 24 24" fill="none"><path d="M20 6L9 17l-5-5" stroke="currentColor" stroke-width="3" stroke-linecap="round" stroke-linejoin="round"/></svg>',
      dl:'<svg viewBox="0 0 24 24" fill="none"><path d="M12 3v12m0 0l-4-4m4 4l4-4M5 21h14" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/></svg>',
      stream:'<svg viewBox="0 0 24 24" fill="none"><circle cx="12" cy="12" r="9" stroke="currentColor" stroke-width="2"/><path d="M10 8l6 4-6 4V8z" fill="currentColor"/></svg>',
      trash:'<svg viewBox="0 0 24 24" fill="none"><path d="M4 7h16M9 7V4h6v3m-7 0v12a1 1 0 001 1h6a1 1 0 001-1V7" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/></svg>',
      link:'<svg viewBox="0 0 24 24" fill="none"><path d="M10 13a5 5 0 007 0l3-3a5 5 0 00-7-7l-1 1" stroke="currentColor" stroke-width="2" stroke-linecap="round"/><path d="M14 11a5 5 0 00-7 0l-3 3a5 5 0 007 7l1-1" stroke="currentColor" stroke-width="2" stroke-linecap="round"/></svg>',
      recheck:'<svg viewBox="0 0 24 24" fill="none"><path d="M20 6L9 17l-5-5" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/><circle cx="12" cy="12" r="9" stroke="currentColor" stroke-width="1.5"/></svg>',
      file:'<svg viewBox="0 0 24 24" fill="none"><path d="M14 3H7a2 2 0 00-2 2v14a2 2 0 002 2h10a2 2 0 002-2V8l-5-5z" stroke="currentColor" stroke-width="2" stroke-linejoin="round"/></svg>',
      x:'<svg viewBox="0 0 24 24" fill="none"><path d="M6 6l12 12M18 6L6 18" stroke="currentColor" stroke-width="2" stroke-linecap="round"/></svg>',
      warn:'<svg viewBox="0 0 24 24" fill="none"><path d="M12 3l9 16H3l9-16zM12 10v4M12 17h.01" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/></svg>',
      logout:'<svg viewBox="0 0 24 24" fill="none"><path d="M9 21H5a2 2 0 01-2-2V5a2 2 0 012-2h4M16 17l5-5-5-5M21 12H9" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/></svg>',
      seq:'<svg viewBox="0 0 24 24" fill="none"><path d="M3 6h13M3 12h9M3 18h5M18 9l3-3 3 3M21 6v12" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/></svg>'};
    function ftSvg(t){if(t==='iso')return '<svg viewBox="0 0 24 24" fill="none"><circle cx="12" cy="12" r="9" stroke="#fff" stroke-width="2"/><circle cx="12" cy="12" r="2.5" fill="#fff"/></svg>';if(t==='video')return '<svg viewBox="0 0 24 24" fill="none"><rect x="2" y="5" width="14" height="14" rx="2" stroke="#fff" stroke-width="2"/><path d="M16 9l6-3v12l-6-3" stroke="#fff" stroke-width="2" stroke-linejoin="round"/></svg>';if(t==='archive')return '<svg viewBox="0 0 24 24" fill="none"><rect x="4" y="3" width="16" height="18" rx="2" stroke="#fff" stroke-width="2"/><path d="M12 3v3m-2 0h4m-2 3v3" stroke="#fff" stroke-width="2" stroke-linecap="round"/></svg>';if(t==='app')return '<svg viewBox="0 0 24 24" fill="none"><path d="M12 2l3 3-3 3-3-3 3-3zM5 9l3 3-3 3-3-3 3-3zM19 9l3 3-3 3-3-3zM12 16l3 3-3 3-3-3z" stroke="#fff" stroke-width="1.6" stroke-linejoin="round"/></svg>';if(t==='magnet')return '<svg viewBox="0 0 24 24" fill="none"><path d="M5 4h4v8a3 3 0 006 0V4h4v8a7 7 0 01-14 0V4z" stroke="#fff" stroke-width="2" stroke-linejoin="round"/><path d="M5 8h4M15 8h4" stroke="#fff" stroke-width="2"/></svg>';return '<svg viewBox="0 0 24 24" fill="none"><path d="M14 3H7a2 2 0 00-2 2v14a2 2 0 002 2h10a2 2 0 002-2V8l-5-5z" stroke="#fff" stroke-width="2" stroke-linejoin="round"/></svg>';}
    const KINDLBL={http:'HTTP',torrent:'BitTorrent',ftp:'FTP',sftp:'SFTP',hls:'HLS'};
    function ftype(t){const n=t.name.toLowerCase();if(t.statusToken==='metadata')return 'magnet';if(/\.iso($|\?)/.test(n))return 'iso';if(t.kind==='torrent'&&/\.(mkv|mp4|avi|mov)/.test(n))return 'video';if(/\.(mkv|mp4|avi|mov|m3u8|webm)/.test(n)||t.kind==='hls')return 'video';if(/\.(zip|gz|tar|7z|rar|dmg|zst|xz)/.test(n))return 'archive';if(/\.(app|xip|pkg|exe|dmg)/.test(n))return 'app';return 'doc';}
    function esc(s){return String(s==null?'':s).replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));}
    function fmtSize(b){if(b==null)return '—';if(b<1)return '0 B';if(b<1024)return Math.round(b)+' B';const u=['KB','MB','GB','TB'];let i=-1;do{b/=1024;i++;}while(b>=1024&&i<u.length-1);return b.toFixed(b<10?1:0)+' '+u[i];}
    function fmtSpeed(b){return b>0?fmtSize(b)+'/s':'—';}
    function fmtEta(s){if(s==null||s<=0||!isFinite(s))return null;s=Math.round(s);if(s<60)return s+'s';if(s<3600)return Math.floor(s/60)+'m';if(s<86400)return Math.floor(s/3600)+'h '+Math.floor(s%3600/60)+'m';return Math.floor(s/86400)+'d';}
    function fmtWhen(sec){const d=new Date(sec*1000),now=new Date();const same=d.toDateString()===now.toDateString();const t=d.toLocaleTimeString([],{hour:'2-digit',minute:'2-digit'});return same?('Today '+t):(d.toLocaleDateString([],{month:'short',day:'numeric'})+' '+t);}
    function toast(m,ic){const w=$('#toasts');const e=document.createElement('div');e.className='toast';e.innerHTML=(ic||ICON.check)+'<span>'+esc(m)+'</span>';w.appendChild(e);setTimeout(()=>{e.classList.add('out');setTimeout(()=>e.remove(),300);},2400);}
    function copy(t){navigator.clipboard&&navigator.clipboard.writeText(t).catch(()=>{});toast('Copied',ICON.copy);}
    async function api(path,opts){const r=await fetch(path,opts||{});if(r.status===401){location.href='/';throw new Error('auth');}if(r.status===403){toast('Read-only mode — change blocked',ICON.warn);throw new Error('ro');}if(!r.ok)throw new Error('http '+r.status);return r;}
    function post(path){return api(path,{method:'POST'});}
    // theme
    function applyTheme(t,persist){if(!THEMES.includes(t))t=BOOT.theme;document.documentElement.dataset.theme=t;if(persist){try{localStorage.setItem('goel-web-theme',t);}catch(_){}}}
    // Apply the saved choice if the user made one, else the server default — WITHOUT
    // persisting, so a browser that never picks a theme keeps following the
    // server's default (and adopts it when the desktop changes it).
    applyTheme((()=>{try{return localStorage.getItem('goel-web-theme');}catch(_){return null;}})()||BOOT.theme,false);
    // header identity
    $('#uname').textContent=BOOT.username;$('#sbUser').textContent=BOOT.username;$('#avatar').textContent=(BOOT.username[0]||'A').toUpperCase();
    if(BOOT.readOnly){$('#roBanner').hidden=false;$('#btnAdd').style.display='none';}
    // panel init
    if(!S.panel){$('#detail').classList.add('hidden');}else{$('#btnPanel').classList.add('active');}
    // ---- view switching ----
    function switchView(v){if(!v)return;S.view=v;$$('#sidebar .s-item').forEach(it=>it.classList.toggle('active',it.dataset.view===v&&(v!=='library'||it.dataset.filter===S.filter)));$$('.view').forEach(el=>el.hidden=true);$('#v-'+v).hidden=false;$('#btnPanel').style.display=v==='library'?'':'none';$('#detail').style.display=v==='library'?'':'none';if(v==='library')renderList();else if(v==='history')loadHistory();else if(v==='settings')renderSettings();closeSidebar();}
    // ---- list ----
    function matches(t){if(S.search&&!t.name.toLowerCase().includes(S.search))return false;if(S.filter==='all')return true;if(S.filter==='active')return t.statusToken==='downloading'||t.statusToken==='metadata'||t.statusToken==='verifying'||t.statusToken==='queued';if(S.filter==='paused')return t.statusToken==='paused';if(S.filter==='completed')return t.statusToken==='completed';if(S.filter==='seeding')return t.statusToken==='seeding';if(S.filter==='failed')return t.statusToken==='failed';return true;}
    function counts(){const c={all:S.tasks.length,active:0,paused:0,completed:0,seeding:0,failed:0};S.tasks.forEach(t=>{const s=t.statusToken;if(s==='downloading'||s==='metadata'||s==='verifying'||s==='queued')c.active++;if(s==='paused')c.paused++;if(s==='completed')c.completed++;if(s==='seeding')c.seeding++;if(s==='failed')c.failed++;});$$('[data-c]').forEach(e=>{if(c[e.dataset.c]!=null)e.textContent=c[e.dataset.c];});}
    function totals(){let d=0,u=0;S.tasks.forEach(t=>{d+=t.downSpeed||0;u+=t.upSpeed||0;});$('#down').textContent=fmtSpeed(d)==='—'?'0 B/s':fmtSpeed(d);$('#up').textContent=fmtSpeed(u)==='—'?'0 B/s':fmtSpeed(u);$('#sbCount').textContent=S.tasks.length+' download'+(S.tasks.length===1?'':'s');}
    function stateAct(t){const s=t.statusToken;if(s==='paused'||s==='queued')return 'resume';if(s==='failed')return 'retry';if(s==='completed'||s==='seeding')return null;return 'pause';}
    function renderList(){counts();totals();const list=S.tasks.filter(matches);const rows=$('#rows');if(!list.length){rows.innerHTML='<div class="empty">'+ICON.dl+'<h4>Nothing here</h4><p>No downloads match this filter. Tap <b>Add</b> to queue a URL, magnet, or torrent.</p></div>';return;}rows.innerHTML=list.map(t=>{const p=(t.progress*100);const ft=ftype(t);const act=stateAct(t);const btn=(act&&S.write)?'<button class="sbtn" data-act="'+act+'" data-id="'+t.id+'">'+(act==='pause'?ICON.pause:act==='retry'?ICON.retry:ICON.play)+'</button>':'<div style="width:28px"></div>';return '<div class="row '+(t.id===S.sel?'sel':'')+'" data-id="'+t.id+'"><div class="c ncell">'+btn+'<div class="ftype ft-'+ft+'">'+ftSvg(ft)+'</div><div class="nmeta"><div class="nline"><span class="ntext">'+esc(t.name)+'</span><span class="kb kb-'+t.kind+'">'+(KINDLBL[t.kind]||t.kind).toUpperCase()+'</span></div><div class="mp '+t.statusToken+'"><i style="width:'+p+'%"></i></div></div></div><div class="c r">'+fmtSize(t.totalBytes)+'</div><div class="c hide-xs"><div class="scell"><span class="sdot st-'+t.statusToken+'"></span><span class="stext">'+esc(t.status)+(t.statusToken==='downloading'?' · '+p.toFixed(0)+'%':'')+'</span></div></div><div class="c r dspd hide-sm">'+(t.downSpeed>0?fmtSpeed(t.downSpeed):'—')+'</div></div>';}).join('');}
    // ---- detail ----
    function togglePanel(f){S.panel=f==null?!S.panel:f;$('#detail').classList.toggle('hidden',!S.panel);$('#btnPanel').classList.toggle('active',S.panel);}
    async function loadDetail(){if(S.sel==null){renderDetail(null);return;}try{const r=await api('/api/task?id='+S.sel);S.detail=await r.json();renderDetail(S.detail);}catch(_){renderDetail(null);}}
    function renderDetail(d){const c=$('#detailBody');if(!d){c.innerHTML='<div class="empty" style="padding:40px 26px">'+ICON.file+'<h4>No download selected</h4><p>Pick a download to see its files, peers, progress and options.</p></div>';return;}const t=d.row;const ft=ftype(t);const p=t.progress*100;const tabs=['general','details','progress','files','peers'];c.innerHTML='<div class="dhead"><div class="dtop"><div class="ftype ft-'+ft+'">'+ftSvg(ft)+'</div><div style="min-width:0"><div class="dname">'+esc(t.name)+'</div><div class="dsub">'+esc(t.status)+' · '+(KINDLBL[t.kind]||t.kind)+'</div></div><button class="dx" data-x>'+ICON.x+'</button></div><div class="dact">'+detailActions(t)+'</div></div><div class="tabs">'+tabs.map(x=>'<div class="tab '+(x===S.tab?'active':'')+'" data-tab="'+x+'">'+x[0].toUpperCase()+x.slice(1)+'</div>').join('')+'</div><div class="tbody">'+pane(S.tab,d)+'</div>';}
    function detailActions(t){let a='';const s=t.statusToken;if(S.write){if(s==='downloading'||s==='metadata'||s==='verifying'||s==='queued')a+='<button class="mbtn" data-act="pause" data-id="'+t.id+'">'+ICON.pause+'Pause</button>';else if(s==='paused')a+='<button class="mbtn accent" data-act="resume" data-id="'+t.id+'">'+ICON.play+'Resume</button>';else if(s==='failed')a+='<button class="mbtn accent" data-act="retry" data-id="'+t.id+'">'+ICON.retry+'Retry</button>';}if(t.streamable){a+='<button class="mbtn" data-stream="'+t.id+'">'+ICON.stream+'Stream</button>';a+='<a class="mbtn" href="/stream?id='+t.id+'" download>'+ICON.dl+'Download</a>';}a+='<button class="mbtn" data-copy="'+esc(t.source)+'">'+ICON.link+'Copy link</button>';if(S.write)a+='<button class="mbtn danger" data-remove="'+t.id+'">'+ICON.trash+'Remove</button>';return a;}
    function kv(k,v){return '<div class="kv"><span class="k">'+k+'</span><span class="v">'+v+'</span></div>';}
    function pane(tab,d){const t=d.row;const p=t.progress*100;if(tab==='general'){let h='<div class="dpw"><div class="dptop"><span class="dpct">'+p.toFixed(0)+'%</span><span class="dpsz">'+fmtSize(t.doneBytes)+' / '+fmtSize(t.totalBytes)+'</span></div><div class="dpbar"><i style="width:'+p+'%"></i></div></div>';if(t.statusToken==='failed'&&t.error)h+='<div style="background:var(--red-soft);color:var(--red);border-radius:9px;padding:11px;font-size:12px;margin-bottom:8px;line-height:1.45">⚠ '+esc(t.error)+'</div>';h+=kv('Save path','<span class="ell">'+esc(d.savePath)+'</span><button class="cbtn" data-copy="'+esc(d.savePath)+'">'+ICON.copy+'</button>');h+=kv('Downloaded',fmtSize(t.doneBytes));if(t.kind==='torrent'){h+=kv('Uploaded',fmtSize(t.upBytes));h+=kv('Share ratio',t.ratio.toFixed(2));}const eta=fmtEta(t.etaSeconds);if(eta)h+=kv('ETA',eta);h+=kv('Speed','↓ '+fmtSpeed(t.downSpeed)+(t.kind==='torrent'?' &nbsp; ↑ '+fmtSpeed(t.upSpeed):''));h+=kv('Protocol',KINDLBL[t.kind]||t.kind);h+=kv('Source','<span class="ell">'+esc(t.source)+'</span><button class="cbtn" data-copy="'+esc(t.source)+'">'+ICON.copy+'</button>');return h;}
    if(tab==='details'){let h='';if(t.kind==='torrent'){h+=kv('Info hash','<span class="ell" style="max-width:150px;font-family:ui-monospace,monospace;font-size:11px">'+esc(d.infoHash||'—')+'</span>');h+=kv('Seeds',(t.seeds!=null?t.seeds:'—')+'');h+=kv('Peers',t.conns+'');h+=kv('Sequential',d.sequential?'On':'Off');if(d.trackers.length){h+='<div class="slbl">Trackers</div>';h+=d.trackers.map(tr=>'<div class="kv"><span class="k" style="max-width:160px;overflow:hidden;text-overflow:ellipsis;font-family:ui-monospace,monospace;font-size:11px">'+esc(tr.host||tr.url)+'</span><span class="v">'+esc(tr.status)+'</span></div>').join('');}}else{h+=kv('Server',esc(d.server||'—'));h+=kv('MIME',esc(d.mimeType||'—'));h+=kv('Connections',t.conns+'');h+=kv('Segments',t.conns+'');}return h||'<p class="fhint">No extra details.</p>';}
    if(tab==='progress'){if(t.kind==='torrent'&&d.pieces&&d.pieces.length){const cells=d.pieces.map(v=>'<span class="'+(v>=1?'f':(v>0?'p':''))+'"></span>').join('');return '<div class="slbl">Piece map · '+d.pieces.length+' buckets</div><div class="pieces">'+cells+'</div>';}if(d.connections&&d.connections.length){return '<div class="slbl">'+d.connections.length+' segments</div>'+d.connections.map(cn=>'<div style="margin-bottom:9px"><div style="display:flex;justify-content:space-between;font-size:11px;color:var(--text-dim);margin-bottom:4px"><span>'+esc(cn.label)+'</span><span>'+(cn.progress*100).toFixed(0)+'%</span></div><div class="dpbar" style="height:6px"><i style="width:'+(cn.progress*100)+'%"></i></div></div>').join('');}return '<div class="dpw"><div class="dptop"><span class="dpct">'+p.toFixed(0)+'%</span></div><div class="dpbar"><i style="width:'+p+'%"></i></div></div><p class="fhint">Live piece/segment data appears here while the transfer runs.</p>';}
    if(tab==='files'){if(!d.files.length)return '<div class="frow"><div class="fchk on">'+ICON.check+'</div><div class="finfo"><div class="fname">'+esc(t.name)+'</div><div class="fbar"><i style="width:'+p+'%"></i></div></div><span class="fsz">'+fmtSize(t.totalBytes)+'</span></div><p class="fhint" style="margin-top:12px">Single-file download.</p>';return d.files.map(f=>'<div class="frow"><div class="fchk '+(f.priority!=='skip'?'on':'')+'" data-fchk="'+f.id+'" data-skip="'+(f.priority==='skip')+'">'+ICON.check+'</div><div class="finfo"><div class="fname">'+esc(f.name)+'</div><div class="fbar"><i style="width:'+(f.progress*100).toFixed(0)+'%"></i></div></div><span class="fsz">'+fmtSize(f.size)+'</span><span class="fprio '+(f.priority==='high'?'high':'')+'" data-fprio="'+f.id+'" data-cur="'+f.priority+'">'+f.priority+'</span></div>').join('');}
    if(tab==='peers'){if(t.kind==='torrent'){const rows=(d.connections||[]);let h='<div class="slbl">'+(t.seeds!=null?t.seeds:0)+' seeds · '+t.conns+' peers</div><div class="crow h"><span>Peer</span><span class="cd">↓</span><span class="cu">↑</span></div>';if(!rows.length)h+='<p class="fhint">No connected peers right now.</p>';h+=rows.map(c=>'<div class="crow"><span class="cip">'+esc(c.label)+'</span><span class="cd">'+fmtSpeed(c.down)+'</span><span class="cu">'+fmtSpeed(c.up)+'</span></div>').join('');return h;}const rows=(d.connections||[]);let h='<div class="slbl">'+t.conns+' connections</div><div class="crow h"><span>Segment</span><span class="cd">↓</span><span class="cu">range</span></div>';h+=rows.map(c=>'<div class="crow"><span class="cip">'+esc(c.label)+'</span><span class="cd">'+fmtSpeed(c.down)+'</span><span class="cu" style="color:var(--text-faint)">'+esc(c.detail)+'</span></div>').join('');return rows.length?h:h+'<p class="fhint">Segment data appears while downloading.</p>';}
    return '';}
    // ---- actions ----
    async function doAct(id,act){try{if(act==='pause')await post('/api/pause?id='+id);else if(act==='resume')await post('/api/resume?id='+id);else if(act==='retry')await post('/api/retry?id='+id);toast(act[0].toUpperCase()+act.slice(1)+'d');refresh();}catch(_){}}
    async function removeTask(id,data){if(data&&!confirm("Delete the downloaded files from disk too? This permanently removes them and can't be undone."))return;try{await post('/api/remove?id='+id+'&data='+(data?1:0));if(S.sel===id){S.sel=null;renderDetail(null);}toast(data?'Removed with data':'Removed',ICON.trash);refresh();}catch(_){}}
    // ---- add ----
    function openAdd(){$('#scrim').innerHTML='<div class="modal"><div class="mhead"><div class="mic">'+ICON.link+'</div><h3>Add download</h3></div><div class="mbody"><label class="flabel">URL, magnet, FTP or SFTP link</label><textarea class="finput" id="addUrl" placeholder="https://example.com/file.iso&#10;magnet:?xt=urn:btih:...&#10;sftp://user@host/path/file.zip"></textarea><div class="fhint">Paste multiple lines to batch-add. Torrents/files download to the server running Goel°.</div><div class="twocol"><div class="fg"><label class="flabel">Save to <span class="chip chip-w">Server folder</span></label><input class="finput" id="addFolder" placeholder="Default folder (leave blank)"></div><div class="fg" style="flex:0 0 130px"><label class="flabel">Priority</label><select class="finput" id="addPrio"><option value="normal">Normal</option><option value="high">High</option><option value="low">Low</option></select></div></div><label style="display:flex;align-items:center;gap:8px;margin-top:14px;font-size:12.5px;cursor:pointer"><input type="checkbox" id="addPaused"> Add paused</label></div><div class="mfoot"><button class="btn" data-close>Cancel</button><button class="btn primary" id="addGo">Add to queue</button></div></div>';openModal();setTimeout(()=>$('#addUrl').focus(),50);$('#addGo').onclick=async()=>{const url=$('#addUrl').value.trim();if(!url){toast('Enter a URL or magnet first');return;}try{const r=await api('/api/add',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({url:url,folder:$('#addFolder').value.trim(),priority:$('#addPrio').value,paused:$('#addPaused').checked})});const j=await r.json();closeModal();S.filter='all';switchView('library');toast((j.added||1)>1?('Added '+j.added+' downloads'):'Added to queue');refresh();}catch(_){}};}
    function openModal(){$('#scrim').classList.add('open');}
    function closeModal(){const s=$('#scrim');s.classList.remove('open');setTimeout(()=>{if(!s.classList.contains('open'))s.innerHTML='';},200);}
    // ---- history ----
    async function loadHistory(){const pad=$('#histPad');pad.innerHTML='<div class="ph">History</div><div class="psub">Completed &amp; removed downloads. Re-queue any of them in one click.</div><div class="card" id="histCard"><p class="fhint" style="padding:8px">Loading…</p></div>';try{const r=await api('/api/history');const h=await r.json();const card=$('#histCard');if(!h.length){card.innerHTML='<p class="fhint" style="padding:14px">No history yet.</p>';return;}card.innerHTML=h.map(e=>{const ft=ftype({name:e.name,kind:e.kind,statusToken:''});return '<div class="hrow"><div class="hic ft-'+ft+'">'+ftSvg(ft)+'</div><div style="min-width:0"><div class="ntext">'+esc(e.name)+'</div><div style="font-size:11px;color:var(--text-faint)">'+(KINDLBL[e.kind]||e.kind)+' · '+fmtWhen(e.completedAt)+'</div></div><div class="c r" style="color:var(--text-dim)">'+fmtSize(e.totalBytes)+'</div><div class="c r hide-sm" style="color:var(--text-faint);font-size:11.5px">'+esc(e.savePath.split('/').slice(-1)[0]||'')+'</div><div style="display:flex;gap:6px">'+(S.write?'<button class="mbtn" data-readd="'+esc(e.source)+'">'+ICON.retry+'Re-add</button><button class="mbtn danger" data-hrm="'+e.id+'">'+ICON.trash+'</button>':'')+'</div></div>';}).join('');}catch(_){$('#histCard').innerHTML='<p class="fhint" style="padding:14px">Could not load history.</p>';}}
    // ---- settings ----
    function renderSettings(){const cur=document.documentElement.dataset.theme;$('#setPad').innerHTML='<div class="ph">Settings</div><div class="psub">These apply to your browser. Server options (port, sign-in, password) are managed in the desktop app under Settings → Web Access.</div>'+
      '<div class="card pd"><div class="srow"><div class="sinfo"><div class="sname">Web theme</div><div class="sdesc">Independent of the desktop app — this choice is remembered in <b>this browser</b> only. The desktop sets the default a new browser starts with.</div></div></div><div class="seg" id="themeSeg">'+THEMES.map(t=>'<button data-th="'+t+'" class="'+(t===cur?'on':'')+'"><span class="sw" style="background:'+THEME_ACCENT[t]+'"></span>'+THEME_LABEL[t]+'</button>').join('')+'</div></div>'+
      '<div class="card pd"><div class="srow"><div class="sinfo"><div class="sname">Access <span class="chip '+(BOOT.readOnly?'chip-d':'chip-w')+'">'+(BOOT.readOnly?'Read-only':'Full control')+'</span></div><div class="sdesc">Signed in as <b>'+esc(BOOT.username)+'</b>. '+(BOOT.readOnly?'This session can view and stream but not change downloads.':'This session can add, remove, and manage downloads.')+'</div></div></div>'+
      '<div class="srow"><div class="sinfo"><div class="sname">Managed on the desktop <span class="chip chip-d">'+ICON.warn+'Desktop</span></div><div class="sdesc">Port, sign-in username/password, LAN access, read-only, and session length live in the app (Settings → Web Access). A native folder picker, Reveal in Finder, clipboard capture, and notifications also stay on the Mac running Goel°.</div></div></div></div>'+
      '<div class="card pd"><div class="srow"><div class="sinfo"><div class="sname">Sign out</div><div class="sdesc">End this browser session.</div></div><div class="sctl"><button class="btn" id="btnLogout">'+ICON.logout+' Sign out</button></div></div></div>';}
    async function logout(){try{await post('/logout');}catch(_){}location.href='/';}
    // ---- SSE / polling ----
    let es=null,live=false;
    function connect(){try{es=new EventSource('/api/events');es.onmessage=e=>{live=true;S.tasks=JSON.parse(e.data);if(S.view==='library')renderList();else{counts();totals();}};es.onerror=()=>{live=false;};}catch(_){live=false;}}
    async function refresh(){try{const r=await api('/api/tasks');S.tasks=await r.json();if(S.view==='library')renderList();else{counts();totals();}}catch(_){}}
    // detail refresh loop
    setInterval(()=>{if(!live)refresh();},2500);
    setInterval(()=>{if(S.sel!=null&&S.view==='library'&&S.panel){const t=S.tasks.find(x=>x.id===S.sel);if(!t||t.statusToken!=='completed')loadDetail();}},1600);
    // ---- events ----
    $('#sidebar').addEventListener('click',e=>{const it=e.target.closest('.s-item');if(!it)return;if(it.dataset.filter)S.filter=it.dataset.filter;switchView(it.dataset.view);});
    $('#hamburger').onclick=()=>{$('#sidebar').classList.toggle('open');$('#sbBackdrop').classList.toggle('show');};
    $('#sbBackdrop').onclick=closeSidebar;function closeSidebar(){$('#sidebar').classList.remove('open');$('#sbBackdrop').classList.remove('show');}
    $('#search').addEventListener('input',e=>{S.search=e.target.value.toLowerCase();renderList();});
    $('#btnAdd').onclick=openAdd;$('#btnPanel').onclick=()=>togglePanel();
    $('#rows').addEventListener('click',e=>{const b=e.target.closest('.sbtn');if(b){e.stopPropagation();doAct(b.dataset.id,b.dataset.act);return;}const row=e.target.closest('.row');if(row){S.sel=row.dataset.id;renderList();if(!S.panel)togglePanel(true);loadDetail();}});
    $('#rows').addEventListener('contextmenu',e=>{const row=e.target.closest('.row');if(!row)return;e.preventDefault();S.sel=row.dataset.id;renderList();loadDetail();openMenu(e.clientX,e.clientY,row.dataset.id);});
    $('#detail').addEventListener('click',e=>{const tab=e.target.closest('.tab');if(tab){S.tab=tab.dataset.tab;renderDetail(S.detail);return;}if(e.target.closest('[data-x]')){togglePanel(false);return;}const cp=e.target.closest('[data-copy]');if(cp){copy(cp.dataset.copy);return;}const b=e.target.closest('[data-act]');if(b){doAct(b.dataset.id,b.dataset.act);return;}const st=e.target.closest('[data-stream]');if(st){window.open('/stream?id='+st.dataset.stream,'_blank');return;}const rm=e.target.closest('[data-remove]');if(rm){openRemove(rm.dataset.remove,e);return;}const fc=e.target.closest('[data-fchk]');if(fc){toggleFile(fc.dataset.fchk,fc.dataset.skip==='true');return;}const fp=e.target.closest('[data-fprio]');if(fp){cyclePrio(fp.dataset.fprio,fp.dataset.cur);return;}});
    async function toggleFile(fid,wasSkip){try{await post('/api/file-priority?id='+S.sel+'&file='+fid+'&prio='+(wasSkip?'normal':'skip'));loadDetail();}catch(_){}}
    async function cyclePrio(fid,cur){const order=['low','normal','high'];let i=order.indexOf(cur);const next=order[(i+1)%order.length];try{await post('/api/file-priority?id='+S.sel+'&file='+fid+'&prio='+next);loadDetail();}catch(_){}}
    // context + remove menus
    function closeMenus(){$$('.menu').forEach(m=>m.remove());}
    document.addEventListener('click',e=>{if(!e.target.closest('.menu'))closeMenus();},true);
    document.addEventListener('keydown',e=>{if(e.key==='Escape'){closeMenus();closeModal();}});
    function buildMenu(x,y,items){closeMenus();const m=document.createElement('div');m.className='menu';m.innerHTML=items.map(it=>it.sep?'<div class="msep"></div>':'<div class="mi '+(it.danger?'danger':'')+'" data-k="'+it.k+'">'+(it.i||'')+'<span class="t">'+it.l+'</span></div>').join('');document.body.appendChild(m);const r=m.getBoundingClientRect();m.style.left=Math.min(x,innerWidth-r.width-8)+'px';m.style.top=Math.min(y,innerHeight-r.height-8)+'px';m.addEventListener('click',ev=>{const el=ev.target.closest('.mi');if(!el)return;const it=items.find(z=>z.k===el.dataset.k);if(it&&it.act)it.act();closeMenus();});}
    function openMenu(x,y,id){const t=S.tasks.find(z=>z.id===id);if(!t)return;const items=[];const act=stateAct(t);if(S.write&&act)items.push({k:'act',l:act[0].toUpperCase()+act.slice(1),i:act==='pause'?ICON.pause:act==='retry'?ICON.retry:ICON.play,act:()=>doAct(id,act)});items.push({k:'copy',l:'Copy source link',i:ICON.link,act:()=>copy(t.source)});if(t.streamable)items.push({k:'stream',l:'Stream',i:ICON.stream,act:()=>window.open('/stream?id='+id,'_blank')});if(S.write&&t.kind==='torrent'){items.push({sep:1});items.push({k:'recheck',l:'Force recheck',i:ICON.recheck,act:async()=>{try{await post('/api/recheck?id='+id);toast('Rechecking');}catch(_){}}});}if(S.write){items.push({sep:1});items.push({k:'rm',l:'Remove from list',i:ICON.trash,danger:1,act:()=>removeTask(id,false)});items.push({k:'rmd',l:'Remove with data',i:ICON.trash,danger:1,act:()=>removeTask(id,true)});}buildMenu(x,y,items);}
    function openRemove(id,ev){const x=ev?ev.clientX-160:innerWidth/2,y=ev?ev.clientY+6:innerHeight/2;buildMenu(x,y,[{k:'rm',l:'Remove from list',i:ICON.trash,danger:1,act:()=>removeTask(id,false)},{k:'rmd',l:'Remove with data',i:ICON.trash,danger:1,act:()=>removeTask(id,true)}]);}
    // user menu
    $('#btnUser').onclick=e=>{e.stopPropagation();const r=$('#btnUser').getBoundingClientRect();buildMenu(r.right-210,r.bottom+6,[{k:'set',l:'Settings',i:ICON.file,act:()=>switchView('settings')},{k:'out',l:'Sign out',i:ICON.logout,danger:1,act:logout}]);};
    // scrim / pane delegation
    $('#scrim').addEventListener('click',e=>{if(e.target===$('#scrim')||e.target.closest('[data-close]'))closeModal();});
    $('#histPad').addEventListener('click',async e=>{const ra=e.target.closest('[data-readd]');if(ra){try{await api('/api/add',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({url:ra.dataset.readd})});toast('Re-added to queue');switchView('library');refresh();}catch(_){}return;}const hr=e.target.closest('[data-hrm]');if(hr){try{await post('/api/history-remove?id='+hr.dataset.hrm);loadHistory();}catch(_){}}});
    $('#setPad').addEventListener('click',e=>{const th=e.target.closest('[data-th]');if(th){applyTheme(th.dataset.th,true);$$('#themeSeg button').forEach(b=>b.classList.toggle('on',b===th));toast('Theme: '+THEME_LABEL[th.dataset.th]);return;}if(e.target.closest('#btnLogout'))logout();});
    // boot
    connect();refresh();renderDetail(null);
    })();
    """#
}
