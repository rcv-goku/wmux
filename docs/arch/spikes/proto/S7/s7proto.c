// s7proto.c - W0-D spike S7 (d2d-sidebar-child) prototype.
//
// Question: can a Direct2D/DirectWrite CHILD HWND (the future `WmuxSidebar`)
// sit next to wmux's OpenGL terminal child HWNDs and a WebView2 child in one
// top-level window without z-order problems, resize flicker or redraw gaps?
// Compared against the fallback: ID2D1DCRenderTarget::BindDC inside the
// parent's (double-buffered) WM_PAINT, no child HWND.
//
// Standalone program; NOT part of the wmux build graph. Build:
//   zig cc -O2 -target x86_64-windows-gnu s7proto.c -o s7proto.exe ^
//     -ld2d1 -ldwrite -ld3d11 -ldxgi -ldwmapi -lopengl32 -lgdi32 -luser32 ^
//     -lole32 -lpsapi
// (see build.ps1). WebView2Loader.dll must sit next to the exe for --webview=1.
//
// Focus safety: the top-level is WS_EX_NOACTIVATE|WS_EX_TOOLWINDOW, created
// at (-32000,-32000) and shown with SW_SHOWNOACTIVATE; every SetWindowPos
// carries SWP_NOACTIVATE. A watchdog thread exits with code 99 if any window
// of this process (or a cross-process child of our top-level) ever becomes
// the foreground window. SetFocus/MoveFocus are never called.
//
// Output: JSON lines on stdout and in <out>\results.jsonl; BMP captures in
// <out>\*.bmp.
//
// Layout (mirrors wmux Window.zig): top-level WS_OVERLAPPEDWINDOW|
// WS_CLIPCHILDREN, class CS_DBLCLKS + bg brush, WM_ERASEBKGND -> 1, GDI chrome
// in WM_PAINT; sidebar child (or DC-RT sidebar painted by the parent); two GL
// children (CS_OWNDC, WGL context rendered from a dedicated thread, WM_SIZE
// waits <=16 ms for a frame like Surface.handleResize in live resize); an
// optional WebView2 host child. Every region is a distinct flat color so a
// capture can be classified per pixel.
//
// Options: --mode=hwndrt|flip|dcrt --present=0|1|2 (NONE|IMMEDIATELY|+RETAIN)
//   --sync=1 (render inside WM_SIZE) --defer=1 (DeferWindowPos) --clip=0|1
//   (WS_CLIPSIBLINGS on children) --webview=1 --layered=1 --swhwndrt=1
//   --swdcrt=1 --flipnone=1 --flipvsync=1 --glwait=0 --nocap=1 (storms without
//   captures) --skipclean=1 (DON'T: breaks PrintWindow) --pos=x,y (keep it
//   off-screen) --glswap=1 --nogl2=1 --sblast=1 --steps=N --wgcverbose=1
//   --tests=all|capture,idle,resize,drag,wresize,wdrag,overlap,dpi,devloss,
//           timing,abi,abi_broken,dcrtdbg  --out=DIR --tag=NAME
//
// Measurement caveats found by this spike (see S7-d2d-sidebar-child.md):
// - For an off-screen top-level, BeginPaint returns an empty rcPaint and a
//   NULLREGION clip box: GDI paints and blt presents do not reach the
//   redirection surface; only PrintWindow-driven paints draw.
// - Every PrintWindow variant first services the window tree's paints (a
//   full synchronous repaint); BitBlt from a window DC misses DX content;
//   WGC only sees flip/DirectComposition updates for off-screen windows.
// - So storms check the settled state (after PrintWindow's repaint) and
//   timing is measured in separate capture-free runs (--nocap, timing).

#define WIN32_LEAN_AND_MEAN
#define UNICODE
#define _UNICODE
#define COBJMACROS
#define CINTERFACE
#ifndef _WIN32_WINNT
#define _WIN32_WINNT 0x0A00
#endif
#include <windows.h>
#include <initguid.h>
#include <d2d1.h>
#include <d2d1_1.h>
#include <dwrite.h>
#include <d3d11.h>
#include <dxgi1_2.h>
#include <dwmapi.h>
#include <psapi.h>
#include <GL/gl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>
#include <math.h>

#ifndef PW_RENDERFULLCONTENT
#define PW_RENDERFULLCONTENT 0x00000002
#endif
#ifndef WM_DPICHANGED
#define WM_DPICHANGED 0x02E0
#endif
#define S7_WM_DPICHANGED_BEFOREPARENT 0x02E2
#define S7_WM_DPICHANGED_AFTERPARENT 0x02E3
#define S7_WM_GETDPISCALEDSIZE 0x02E4
#define WM_APP_RUN (WM_APP + 1)

// ---------------------------------------------------------------------------
// Configuration (command line: --key=value)
// ---------------------------------------------------------------------------

enum { MODE_HWNDRT = 0, MODE_FLIP = 1, MODE_DCRT = 2 };
static const char *MODE_NAMES[] = {"hwndrt", "flip", "dcrt"};

static struct Cfg {
    int mode;        // sidebar renderer
    int present;     // hwndrt: 0 NONE (vsync wait), 1 IMMEDIATELY, 2 IMMEDIATELY|RETAIN_CONTENTS
    int sync_paint;  // 1: render inside WM_SIZE (+ValidateRect); 0: InvalidateRect only
    int defer;       // 1: Begin/Defer/EndDeferWindowPos; 0: sequential MoveWindow (wmux today)
    int webview;     // create a WebView2 sibling
    int clip;        // WS_CLIPSIBLINGS on every child
    int layered;     // WS_EX_LAYERED + LWA_ALPHA top-level (wmux background-opacity < 1)
    int sw_dcrt;     // DC render target type SOFTWARE
    int sw_hwndrt;   // HWND render target type SOFTWARE
    int flip_none;   // flip model: DXGI_SCALING_NONE instead of STRETCH
    int flip_vsync;  // flip model: Present(1,0) instead of Present(0,0)
    int gl_wait;     // GL child WM_SIZE waits <=16 ms for a frame (wmux live resize)
    int occl_off;    // WebView2: --disable-features=CalculateNativeWinOcclusion
    int nocopy;      // SWP_NOCOPYBITS on child moves
    int steps;       // storm steps
    int posx, posy;  // initial top-level position (always off-screen)
    int glswap;      // create GL2 before GL1
    int nogl2;       // only one GL pane
    int sblast;      // create the sidebar child after the GL children
    int skipclean;   // WM_PAINT skips re-rendering when nothing changed since the last frame
    int nocap;       // storms without captures (clean timing)
    char tests[512];
    char out[MAX_PATH];
    char tag[128];
} cfg = {MODE_HWNDRT, 1, 1, 0, 0, 1, 0, 0, 0, 0, 0, 1, 0, 0, 60, -32000, -32000, 0, 0, 0, 0, 0, "all", ".", "run"};

// ---------------------------------------------------------------------------
// Colors. Every region fills with a distinct flat color so a capture can be
// classified pixel by pixel.
// ---------------------------------------------------------------------------

typedef struct { BYTE r, g, b; } RGB3;
static const RGB3 COL_PARENT = {0x80, 0x00, 0x00};  // parent client (gaps)
static const RGB3 COL_TAB = {0x40, 0x40, 0x40};     // parent "tab bar"
static const RGB3 COL_DIV = {0x58, 0x58, 0x58};     // parent split divider
static const RGB3 COL_SB = {0x20, 0x30, 0x60};      // sidebar background
static const RGB3 COL_SB2 = {0x60, 0x30, 0x20};     // sidebar alt background (repaint probe)
static const RGB3 COL_SBMARK = {0xFF, 0x00, 0xFF};  // sidebar right-edge marker (3 px)
static const RGB3 COL_RULER = {0xFF, 0xFF, 0x00};   // 100-DIP ruler
static const RGB3 COL_SEL = {0x30, 0x48, 0x90};     // selected row
static const RGB3 COL_TEXT = {0xE6, 0xE6, 0xE6};
static const RGB3 COL_SUBTEXT = {0x9A, 0xA4, 0xB8};
static const RGB3 COL_PILL = {0xFF, 0x99, 0x00};
static const RGB3 COL_PROG_BG = {0x38, 0x44, 0x70};
static const RGB3 COL_PROG = {0x4C, 0xC0, 0x70};
static const RGB3 COL_GL = {0x10, 0x60, 0x20};      // GL clear color
static const RGB3 COL_GLMARK = {0x00, 0xFF, 0xFF};  // GL left-edge marker (3 px)
// GL child WM_ERASEBKGND fill. wmux uses the terminal bg (== GL clear color);
// the spike uses a distinct color to see which layer DWM actually shows.
static const RGB3 COL_GLERASE = {0x10, 0x30, 0x10};
// WebView2 page background / left-edge marker as authored (#0080C0, #FF8000).
// Chromium color-manages to the display profile, so the classifier uses the
// colors measured from the first rendered frame (wv_calibrate).
static RGB3 COL_WV = {0x00, 0x80, 0xC0};
static RGB3 COL_WVMARK = {0xFF, 0x80, 0x00};
static const RGB3 COL_WVHOST = {0x30, 0x30, 0x30};  // WebView2 host HWND (uncovered)
static const RGB3 COL_OVL = {0xFF, 0x40, 0x80};     // D2D overlay child

// ---------------------------------------------------------------------------
// Globals
// ---------------------------------------------------------------------------

static HINSTANCE g_inst;
static HWND g_top, g_sb, g_gl[2], g_wvhost, g_ovl;
static FILE *g_out;
static volatile LONG g_quit;
static UINT g_dpi_override;       // simulated DPI (0 = real GetDpiForWindow)
static int g_sbw_dip = 260;       // sidebar width in DIPs
static int g_sbw_override_px = -1;
static int g_overlap_px;          // sidebar extends this far over GL1 (z-order test)
static int g_alt_bg;              // repaint probe
static int g_inject;              // pending injected D2DERR_RECREATE_TARGET
static int g_in_storm;
static double g_qpf;
// Passive capture: while set, WM_PAINT only records + validates its update
// region (re-invalidated afterwards), so PrintWindow cannot service our
// pending paints and shows what DWM currently has.
static int g_freeze;
static int g_paint_debug;
static HRGN g_frozen_sb, g_frozen_top;
static LONG g_frozen_paints;
// Per-frame samples collected while a storm runs.
#define MAXS 4096
static double S_frame[MAXS], S_draw[MAXS], S_end[MAXS];
static int S_n;
static unsigned g_content_version = 1, g_rendered_version;  // skipclean bookkeeping
static int g_rendered_w, g_rendered_h;
static UINT g_rendered_dpi;

static ID2D1Factory1 *g_d2f;
static IDWriteFactory *g_dwf;
static IDWriteTextFormat *g_tf_title, *g_tf_sub;

typedef UINT(WINAPI *PFN_GetDpiForWindow)(HWND);
typedef BOOL(WINAPI *PFN_SetProcessDpiAwarenessContext)(HANDLE);
static PFN_GetDpiForWindow pGetDpiForWindow;

static struct Counters {
    LONG sb_size, sb_paint, sb_frames, sb_recreate, sb_before, sb_after, sb_printclient;
    LONG top_size, top_paint, top_dpichanged, top_getdpiscaled;
    LONG dc_frames;
    double sb_last_ms, sb_max_ms, sb_sum_ms;
    double enddraw_max_ms;
    double last_enddraw_ms;  // EndDraw (+Present for flip) of the last frame
    double last_draw_ms;     // CPU-side drawing calls of the last frame
    HRESULT last_hr;
} C;

// sequence log for DPI messages (message, hwnd tag, dpi seen)
static char g_seq[4096];
static void seq_add(const char *fmt, ...) {
    size_t n = strlen(g_seq);
    if (n > sizeof(g_seq) - 200) return;
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(g_seq + n, sizeof(g_seq) - n, fmt, ap);
    va_end(ap);
}

static double now_ms(void) {
    LARGE_INTEGER c;
    QueryPerformanceCounter(&c);
    return (double)c.QuadPart * 1000.0 / g_qpf;
}

static void jlog(const char *fmt, ...) {
    char buf[16384];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(buf, sizeof(buf), fmt, ap);
    va_end(ap);
    fprintf(stdout, "%s\n", buf);
    fflush(stdout);
    if (g_out) {
        fprintf(g_out, "%s\n", buf);
        fflush(g_out);
    }
}

static UINT real_dpi(HWND h) {
    if (pGetDpiForWindow && h) {
        UINT d = pGetDpiForWindow(h);
        if (d) return d;
    }
    return 96;
}
static UINT dpi_for(HWND h) { return g_dpi_override ? g_dpi_override : real_dpi(h); }

static const char *tag_of(HWND h) {
    if (h == g_top) return "top";
    if (h == g_sb) return "sidebar";
    if (h == g_gl[0]) return "gl1";
    if (h == g_gl[1]) return "gl2";
    if (h == g_wvhost) return "wvhost";
    if (h == g_ovl) return "overlay";
    return "?";
}

// ---------------------------------------------------------------------------
// Foreground watchdog (in-process; the PowerShell runner has its own sampler)
// ---------------------------------------------------------------------------

static DWORD WINAPI fg_watch(void *arg) {
    (void)arg;
    DWORD me = GetCurrentProcessId();
    while (!g_quit) {
        HWND f = GetForegroundWindow();
        if (f) {
            DWORD pid = 0;
            GetWindowThreadProcessId(f, &pid);
            HWND root = GetAncestor(f, GA_ROOT);
            if (pid == me || (g_top && root == g_top)) {
                jlog("{\"t\":\"FOREGROUND_VIOLATION\",\"hwnd\":\"%p\"}", (void *)f);
                ExitProcess(99);
            }
        }
        Sleep(50);
    }
    return 0;
}

// ---------------------------------------------------------------------------
// Layout (physical pixels, parent client coordinates)
// ---------------------------------------------------------------------------

typedef struct { RECT sb, tab, gl1, gl2, wv, div1, div2; } Layout;
static Layout g_L;

static void compute_layout(int W, int H, Layout *L) {
    UINT dpi = dpi_for(g_top);
    int sbw = g_sbw_override_px >= 0 ? g_sbw_override_px : MulDiv(g_sbw_dip, dpi, 96);
    int tb = MulDiv(32, dpi, 96), gap = MulDiv(5, dpi, 96);
    if (sbw > W - 50) sbw = W - 50;
    if (sbw < 10) sbw = 10;
    SetRect(&L->sb, 0, 0, sbw + g_overlap_px, H);
    SetRect(&L->tab, sbw, 0, W, tb);
    int cx0 = sbw, cw = W - sbw;
    int left_w = cw / 2 - gap / 2;
    SetRect(&L->gl1, cx0, tb, cx0 + left_w, H);
    SetRect(&L->div1, L->gl1.right, tb, L->gl1.right + gap, H);
    int rx0 = L->div1.right;
    if (cfg.webview) {
        int top_h = (H - tb) / 2 - gap / 2;
        SetRect(&L->gl2, rx0, tb, W, tb + top_h);
        SetRect(&L->div2, rx0, L->gl2.bottom, W, L->gl2.bottom + gap);
        SetRect(&L->wv, rx0, L->div2.bottom, W, H);
    } else {
        SetRect(&L->gl2, rx0, tb, W, H);
        SetRectEmpty(&L->div2);
        SetRectEmpty(&L->wv);
    }
}

#define RW(r) (r).left, (r).top, ((r).right - (r).left), ((r).bottom - (r).top)

static void layout(void) {
    RECT c;
    GetClientRect(g_top, &c);
    compute_layout(c.right, c.bottom, &g_L);
    UINT f = SWP_NOZORDER | SWP_NOACTIVATE | SWP_NOOWNERZORDER | (cfg.nocopy ? SWP_NOCOPYBITS : 0);
    if (cfg.defer) {
        HDWP d = BeginDeferWindowPos(5);
        if (d && g_sb) d = DeferWindowPos(d, g_sb, NULL, RW(g_L.sb), f);
        if (d && g_gl[0]) d = DeferWindowPos(d, g_gl[0], NULL, RW(g_L.gl1), f);
        if (d && g_gl[1]) d = DeferWindowPos(d, g_gl[1], NULL, RW(g_L.gl2), f);
        if (d && g_wvhost) d = DeferWindowPos(d, g_wvhost, NULL, RW(g_L.wv), f);
        if (!d || !EndDeferWindowPos(d)) jlog("{\"t\":\"error\",\"what\":\"DeferWindowPos\",\"gle\":%lu}", GetLastError());
    } else {
        // wmux today: Window.layoutNode -> MoveWindow(h, ..., TRUE) per pane.
        if (g_sb) SetWindowPos(g_sb, NULL, RW(g_L.sb), f);
        if (g_gl[0]) SetWindowPos(g_gl[0], NULL, RW(g_L.gl1), f);
        if (g_gl[1]) SetWindowPos(g_gl[1], NULL, RW(g_L.gl2), f);
        if (g_wvhost) SetWindowPos(g_wvhost, NULL, RW(g_L.wv), f);
    }
}

// ---------------------------------------------------------------------------
// DirectWrite text layouts (device independent; rebuilt on width change)
// ---------------------------------------------------------------------------

#define NROWS 40
static IDWriteTextLayout *L_title[NROWS], *L_sub[NROWS];
static float L_width = -1.f;
static float g_title_metrics_h;  // DIP height of row 0 title layout

static void release_layouts(void) {
    for (int i = 0; i < NROWS; i++) {
        if (L_title[i]) IDWriteTextLayout_Release(L_title[i]);
        if (L_sub[i]) IDWriteTextLayout_Release(L_sub[i]);
        L_title[i] = L_sub[i] = NULL;
    }
    L_width = -1.f;
}

static void ensure_layouts(float wdip) {
    if (L_title[0] && fabsf(wdip - L_width) < 0.01f) return;
    release_layouts();
    float maxw = wdip - 16.f - 54.f;
    if (maxw < 10.f) maxw = 10.f;
    for (int i = 0; i < NROWS; i++) {
        wchar_t t[160], s[160];
        if (i == 2 || i == 5)
            swprintf(t, 160, L"Deploy \U0001F680 ready \U0001F642 %d", i);
        else
            swprintf(t, 160, L"Workspace %d \x2014 agent session %c", i, (wchar_t)(L'A' + (i % 26)));
        swprintf(s, 160, L"~/src/project-%d  \x2387 main  \x2713 %d ports", i, i % 4);
        IDWriteFactory_CreateTextLayout(g_dwf, t, (UINT32)wcslen(t), g_tf_title, maxw, 20.f, &L_title[i]);
        IDWriteFactory_CreateTextLayout(g_dwf, s, (UINT32)wcslen(s), g_tf_sub, maxw, 18.f, &L_sub[i]);
    }
    DWRITE_TEXT_METRICS m;
    if (L_title[0] && SUCCEEDED(IDWriteTextLayout_GetMetrics(L_title[0], &m))) g_title_metrics_h = m.height;
    L_width = wdip;
}

// ---------------------------------------------------------------------------
// Shared sidebar drawing (any ID2D1RenderTarget: HWND RT, DC RT, device ctx)
// ---------------------------------------------------------------------------

static D2D1_COLOR_F colf(RGB3 c) {
    D2D1_COLOR_F f = {c.r / 255.f, c.g / 255.f, c.b / 255.f, 1.f};
    return f;
}
static void set_color(ID2D1SolidColorBrush *b, RGB3 c) {
    D2D1_COLOR_F f = colf(c);
    ID2D1SolidColorBrush_SetColor(b, &f);
}
static void fill(ID2D1RenderTarget *rt, ID2D1SolidColorBrush *b, float l, float t, float r, float bt) {
    D2D1_RECT_F rc = {l, t, r, bt};
    ID2D1RenderTarget_FillRectangle(rt, &rc, (ID2D1Brush *)b);
}
static void fill_round(ID2D1RenderTarget *rt, ID2D1SolidColorBrush *b, float l, float t, float r, float bt, float rad) {
    D2D1_ROUNDED_RECT rr = {{l, t, r, bt}, rad, rad};
    ID2D1RenderTarget_FillRoundedRectangle(rt, &rr, (ID2D1Brush *)b);
}

#define ROW0_Y 120.f
static float row_height(int i) { return (i % 3 == 2) ? 62.f : 46.f; }

static void draw_sidebar(ID2D1RenderTarget *rt, ID2D1SolidColorBrush *br, float wdip, float hdip, float dpi) {
    D2D1_MATRIX_3X2_F I = {1, 0, 0, 1, 0, 0};
    ID2D1RenderTarget_SetTransform(rt, &I);
    D2D1_COLOR_F bg = colf(g_alt_bg ? COL_SB2 : COL_SB);
    ID2D1RenderTarget_Clear(rt, &bg);
    // Grayscale AA so ClearType fringes cannot be mistaken for color-emoji pixels.
    ID2D1RenderTarget_SetTextAntialiasMode(rt, D2D1_TEXT_ANTIALIAS_MODE_GRAYSCALE);
    ensure_layouts(wdip);
    float px = 96.f / dpi;  // one device pixel in DIPs
    ID2D1RenderTarget_SetAntialiasMode(rt, D2D1_ANTIALIAS_MODE_ALIASED);
    set_color(br, COL_RULER);
    fill(rt, br, 2.f, 10.f, 6.f, 110.f);  // 100 DIP ruler
    set_color(br, COL_SBMARK);
    fill(rt, br, wdip - 3.f * px, 0.f, wdip, hdip);  // 3 device px right-edge marker
    ID2D1RenderTarget_SetAntialiasMode(rt, D2D1_ANTIALIAS_MODE_PER_PRIMITIVE);
    float y = ROW0_Y;
    for (int i = 0; i < NROWS && y < hdip; i++) {
        float rh = row_height(i);
        if (i == 1) {
            set_color(br, COL_SEL);
            fill_round(rt, br, 8.f, y + 2.f, wdip - 10.f, y + rh - 2.f, 6.f);
        }
        D2D1_POINT_2F o = {16.f, y + 6.f};
        set_color(br, COL_TEXT);
        // Row 5 is the control: same emoji text WITHOUT the color-font flag.
        D2D1_DRAW_TEXT_OPTIONS opts = D2D1_DRAW_TEXT_OPTIONS_CLIP;
        if (i != 5) opts |= D2D1_DRAW_TEXT_OPTIONS_ENABLE_COLOR_FONT;
        if (L_title[i]) ID2D1RenderTarget_DrawTextLayout(rt, o, L_title[i], (ID2D1Brush *)br, opts);
        D2D1_POINT_2F o2 = {16.f, y + 26.f};
        set_color(br, COL_SUBTEXT);
        if (L_sub[i]) ID2D1RenderTarget_DrawTextLayout(rt, o2, L_sub[i], (ID2D1Brush *)br, D2D1_DRAW_TEXT_OPTIONS_CLIP);
        set_color(br, COL_PILL);
        fill_round(rt, br, wdip - 46.f, y + 8.f, wdip - 18.f, y + 24.f, 8.f);
        if (i % 3 == 2) {
            set_color(br, COL_PROG_BG);
            fill(rt, br, 16.f, y + 47.f, wdip - 22.f, y + 51.f);
            set_color(br, COL_PROG);
            fill(rt, br, 16.f, y + 47.f, 16.f + (wdip - 38.f) * (float)((i * 7) % 10) / 10.f, y + 51.f);
        }
        y += rh;
    }
}

// ---------------------------------------------------------------------------
// Sidebar renderer A: ID2D1HwndRenderTarget (ADR-11.1 choice)
// ---------------------------------------------------------------------------

static ID2D1HwndRenderTarget *s_hrt;
static ID2D1SolidColorBrush *s_brush;
static UINT s_rt_dpi;
static UINT s_rt_created_count;
static UINT s_hrt_w, s_hrt_h;  // pixel size last given to the HWND RT

static void hrt_discard(void) {
    if (s_brush) ID2D1SolidColorBrush_Release(s_brush);
    if (s_hrt) ID2D1HwndRenderTarget_Release(s_hrt);
    s_brush = NULL;
    s_hrt = NULL;
}

static D2D1_PRESENT_OPTIONS present_opts(void) {
    if (cfg.present == 0) return D2D1_PRESENT_OPTIONS_NONE;
    if (cfg.present == 1) return D2D1_PRESENT_OPTIONS_IMMEDIATELY;
    return (D2D1_PRESENT_OPTIONS)(D2D1_PRESENT_OPTIONS_IMMEDIATELY | D2D1_PRESENT_OPTIONS_RETAIN_CONTENTS);
}

static HRESULT hrt_create_for(HWND h, UINT dpi, int software, D2D1_PRESENT_OPTIONS po, ID2D1HwndRenderTarget **out) {
    RECT rc;
    GetClientRect(h, &rc);
    D2D1_RENDER_TARGET_PROPERTIES p;
    memset(&p, 0, sizeof(p));
    p.type = software ? D2D1_RENDER_TARGET_TYPE_SOFTWARE : D2D1_RENDER_TARGET_TYPE_DEFAULT;
    p.pixelFormat.format = DXGI_FORMAT_B8G8R8A8_UNORM;
    p.pixelFormat.alphaMode = D2D1_ALPHA_MODE_IGNORE;
    p.dpiX = p.dpiY = (FLOAT)dpi;  // 0 would mean "desktop DPI" (wrong under PMv2)
    p.usage = D2D1_RENDER_TARGET_USAGE_NONE;
    p.minLevel = D2D1_FEATURE_LEVEL_DEFAULT;
    D2D1_HWND_RENDER_TARGET_PROPERTIES hp;
    hp.hwnd = h;
    hp.pixelSize.width = (UINT32)(rc.right > 1 ? rc.right : 1);
    hp.pixelSize.height = (UINT32)(rc.bottom > 1 ? rc.bottom : 1);
    hp.presentOptions = po;
    return ID2D1Factory_CreateHwndRenderTarget((ID2D1Factory *)g_d2f, &p, &hp, out);
}

static HRESULT hrt_create(void) {
    UINT dpi = dpi_for(g_sb);
    HRESULT hr = hrt_create_for(g_sb, dpi, cfg.sw_hwndrt, present_opts(), &s_hrt);
    if (FAILED(hr)) return hr;
    s_rt_dpi = dpi;
    s_rt_created_count++;
    RECT rc;
    GetClientRect(g_sb, &rc);
    s_hrt_w = (UINT)(rc.right > 1 ? rc.right : 1);
    s_hrt_h = (UINT)(rc.bottom > 1 ? rc.bottom : 1);
    D2D1_COLOR_F c = {1, 1, 1, 1};
    hr = ID2D1RenderTarget_CreateSolidColorBrush((ID2D1RenderTarget *)s_hrt, &c, NULL, &s_brush);
    return hr;
}

// ---------------------------------------------------------------------------
// Sidebar renderer B: D2D 1.1 device context + DXGI flip-model swap chain
// ---------------------------------------------------------------------------

// mingw's C macros for methods inherited by D2D 1.1 interfaces (e.g.
// ID2D1DeviceContext_Release) expand to lpVtbl->Release, which does not exist
// in the nested-"Base" C vtables; release through IUnknown instead.
static void com_release(void *p) {
    if (p) ((IUnknown *)p)->lpVtbl->Release((IUnknown *)p);
}

static ID3D11Device *f_dev;
static ID3D11DeviceContext *f_ctx;
static ID2D1Device *f_d2dev;
static ID2D1DeviceContext *f_dc;
static IDXGISwapChain1 *f_sc;
static ID2D1Bitmap1 *f_bmp;
static ID2D1SolidColorBrush *f_brush;
static HRESULT f_last_create_hr;

static void flip_unbind(void) {
    if (f_dc) ID2D1DeviceContext_SetTarget(f_dc, NULL);
    com_release(f_bmp);
    f_bmp = NULL;
}

static HRESULT flip_bind(void) {
    IDXGISurface *surf = NULL;
    HRESULT hr = IDXGISwapChain1_GetBuffer(f_sc, 0, &IID_IDXGISurface, (void **)&surf);
    if (FAILED(hr)) return hr;
    UINT dpi = dpi_for(g_sb);
    D2D1_BITMAP_PROPERTIES1 bp;
    memset(&bp, 0, sizeof(bp));
    bp.pixelFormat.format = DXGI_FORMAT_B8G8R8A8_UNORM;
    bp.pixelFormat.alphaMode = D2D1_ALPHA_MODE_IGNORE;
    bp.dpiX = bp.dpiY = (FLOAT)dpi;
    bp.bitmapOptions = D2D1_BITMAP_OPTIONS_TARGET | D2D1_BITMAP_OPTIONS_CANNOT_DRAW;
    hr = ID2D1DeviceContext_CreateBitmapFromDxgiSurface(f_dc, surf, &bp, &f_bmp);
    IDXGISurface_Release(surf);
    if (FAILED(hr)) return hr;
    ID2D1DeviceContext_SetTarget(f_dc, (struct ID2D1Image *)f_bmp);
    ID2D1RenderTarget_SetDpi((ID2D1RenderTarget *)f_dc, (FLOAT)dpi, (FLOAT)dpi);
    s_rt_dpi = dpi;
    return S_OK;
}

static void flip_discard(void) {
    flip_unbind();
    if (f_brush) ID2D1SolidColorBrush_Release(f_brush);
    if (f_sc) IDXGISwapChain1_Release(f_sc);
    com_release(f_dc);
    com_release(f_d2dev);
    if (f_ctx) {
        // Swap-chain destruction is deferred until the immediate context is
        // flushed; without this a new swap chain on the same HWND can fail.
        ID3D11DeviceContext_ClearState(f_ctx);
        ID3D11DeviceContext_Flush(f_ctx);
        ID3D11DeviceContext_Release(f_ctx);
    }
    if (f_dev) ID3D11Device_Release(f_dev);
    f_brush = NULL;
    f_sc = NULL;
    f_dc = NULL;
    f_d2dev = NULL;
    f_ctx = NULL;
    f_dev = NULL;
}

static HRESULT flip_create(void) {
    D3D_FEATURE_LEVEL fls[] = {D3D_FEATURE_LEVEL_11_1, D3D_FEATURE_LEVEL_11_0, D3D_FEATURE_LEVEL_10_1,
                               D3D_FEATURE_LEVEL_10_0};
    HRESULT hr = D3D11CreateDevice(NULL, D3D_DRIVER_TYPE_HARDWARE, NULL, D3D11_CREATE_DEVICE_BGRA_SUPPORT, fls, 4,
                                   D3D11_SDK_VERSION, &f_dev, NULL, &f_ctx);
    if (FAILED(hr)) {
        f_last_create_hr = hr;
        return hr;
    }
    IDXGIDevice *dx = NULL;
    hr = ID3D11Device_QueryInterface(f_dev, &IID_IDXGIDevice, (void **)&dx);
    if (SUCCEEDED(hr)) hr = ID2D1Factory1_CreateDevice(g_d2f, dx, &f_d2dev);
    if (SUCCEEDED(hr)) hr = ID2D1Device_CreateDeviceContext(f_d2dev, D2D1_DEVICE_CONTEXT_OPTIONS_NONE, &f_dc);
    IDXGIAdapter *ad = NULL;
    IDXGIFactory2 *fac = NULL;
    if (SUCCEEDED(hr)) hr = IDXGIDevice_GetAdapter(dx, &ad);
    if (SUCCEEDED(hr)) hr = IDXGIAdapter_GetParent(ad, &IID_IDXGIFactory2, (void **)&fac);
    if (SUCCEEDED(hr)) {
        RECT rc;
        GetClientRect(g_sb, &rc);
        DXGI_SWAP_CHAIN_DESC1 d;
        memset(&d, 0, sizeof(d));
        d.Width = (UINT)(rc.right > 1 ? rc.right : 1);
        d.Height = (UINT)(rc.bottom > 1 ? rc.bottom : 1);
        d.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
        d.SampleDesc.Count = 1;
        d.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
        d.BufferCount = 2;
        d.Scaling = cfg.flip_none ? DXGI_SCALING_NONE : DXGI_SCALING_STRETCH;
        d.SwapEffect = DXGI_SWAP_EFFECT_FLIP_SEQUENTIAL;
        d.AlphaMode = DXGI_ALPHA_MODE_IGNORE;
        hr = IDXGIFactory2_CreateSwapChainForHwnd(fac, (IUnknown *)f_dev, g_sb, &d, NULL, NULL, &f_sc);
    }
    if (fac) IDXGIFactory2_Release(fac);
    if (ad) IDXGIAdapter_Release(ad);
    if (dx) IDXGIDevice_Release(dx);
    if (SUCCEEDED(hr)) hr = flip_bind();
    if (SUCCEEDED(hr)) {
        D2D1_COLOR_F c = {1, 1, 1, 1};
        hr = ID2D1RenderTarget_CreateSolidColorBrush((ID2D1RenderTarget *)f_dc, &c, NULL, &f_brush);
    }
    f_last_create_hr = hr;
    if (FAILED(hr)) flip_discard();
    else s_rt_created_count++;
    return hr;
}

static void flip_resize(UINT w, UINT h) {
    if (!f_sc || !w || !h) return;
    flip_unbind();
    HRESULT hr = IDXGISwapChain1_ResizeBuffers(f_sc, 0, w, h, DXGI_FORMAT_UNKNOWN, 0);
    if (FAILED(hr)) {
        jlog("{\"t\":\"error\",\"what\":\"ResizeBuffers\",\"hr\":\"0x%08lX\"}", (unsigned long)hr);
        flip_discard();
        return;
    }
    hr = flip_bind();
    if (FAILED(hr)) flip_discard();
}

// ---------------------------------------------------------------------------
// Sidebar renderer C (fallback): ID2D1DCRenderTarget::BindDC in parent paint
// ---------------------------------------------------------------------------

static ID2D1DCRenderTarget *s_dcrt;
static ID2D1SolidColorBrush *s_dcbrush;
static UINT s_dcrt_dpi;
static HDC d_memdc;
static HBITMAP d_bmp;
static HGDIOBJ d_old;
static int d_w, d_h;

static void dcrt_discard(void) {
    if (s_dcbrush) ID2D1SolidColorBrush_Release(s_dcbrush);
    if (s_dcrt) ID2D1DCRenderTarget_Release(s_dcrt);
    s_dcbrush = NULL;
    s_dcrt = NULL;
}

static HRESULT dcrt_create(UINT dpi) {
    D2D1_RENDER_TARGET_PROPERTIES p;
    memset(&p, 0, sizeof(p));
    p.type = cfg.sw_dcrt ? D2D1_RENDER_TARGET_TYPE_SOFTWARE : D2D1_RENDER_TARGET_TYPE_DEFAULT;
    p.pixelFormat.format = DXGI_FORMAT_B8G8R8A8_UNORM;
    p.pixelFormat.alphaMode = D2D1_ALPHA_MODE_IGNORE;
    p.dpiX = p.dpiY = (FLOAT)dpi;
    HRESULT hr = ID2D1Factory_CreateDCRenderTarget((ID2D1Factory *)g_d2f, &p, &s_dcrt);
    if (FAILED(hr)) return hr;
    s_dcrt_dpi = dpi;
    s_rt_created_count++;
    D2D1_COLOR_F c = {1, 1, 1, 1};
    return ID2D1RenderTarget_CreateSolidColorBrush((ID2D1RenderTarget *)s_dcrt, &c, NULL, &s_dcbrush);
}

static void stats_frame(double dt) {
    C.sb_frames++;
    C.sb_last_ms = dt;
    C.sb_sum_ms += dt;
    if (dt > C.sb_max_ms) C.sb_max_ms = dt;
    if (g_in_storm && S_n < MAXS) {
        S_frame[S_n] = dt;
        S_draw[S_n] = C.last_draw_ms;
        S_end[S_n] = C.last_enddraw_ms;
        S_n++;
    }
}

// Paint the sidebar into `target` at rect r via a cached 32-bpp DIB memory DC
// (same double-buffer shape as today's Sidebar.paint).
static void dcrt_paint(HDC target, const RECT *r) {
    double t0 = now_ms();
    int w = r->right - r->left, h = r->bottom - r->top;
    if (w <= 0 || h <= 0) return;
    if (!d_memdc || w != d_w || h != d_h) {
        if (d_memdc) {
            SelectObject(d_memdc, d_old);
            DeleteObject(d_bmp);
            DeleteDC(d_memdc);
        }
        HDC scr = GetDC(NULL);
        d_memdc = CreateCompatibleDC(scr);
        ReleaseDC(NULL, scr);
        BITMAPINFO bi;
        memset(&bi, 0, sizeof(bi));
        bi.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
        bi.bmiHeader.biWidth = w;
        bi.bmiHeader.biHeight = -h;
        bi.bmiHeader.biPlanes = 1;
        bi.bmiHeader.biBitCount = 32;
        bi.bmiHeader.biCompression = BI_RGB;
        void *bits = NULL;
        d_bmp = CreateDIBSection(d_memdc, &bi, DIB_RGB_COLORS, &bits, NULL, 0);
        d_old = SelectObject(d_memdc, d_bmp);
        d_w = w;
        d_h = h;
    }
    UINT dpi = dpi_for(g_top);
    HRESULT hr = S_OK;
    if (!s_dcrt) hr = dcrt_create(dpi);
    if (FAILED(hr)) {
        jlog("{\"t\":\"error\",\"what\":\"CreateDCRenderTarget\",\"hr\":\"0x%08lX\"}", (unsigned long)hr);
        return;
    }
    if (s_dcrt_dpi != dpi) {
        ID2D1RenderTarget_SetDpi((ID2D1RenderTarget *)s_dcrt, (FLOAT)dpi, (FLOAT)dpi);
        s_dcrt_dpi = dpi;
    }
    RECT b = {0, 0, w, h};
    hr = ID2D1DCRenderTarget_BindDC(s_dcrt, d_memdc, &b);
    if (SUCCEEDED(hr)) {
        ID2D1RenderTarget *rt = (ID2D1RenderTarget *)s_dcrt;
        double tb = now_ms();
        ID2D1RenderTarget_BeginDraw(rt);
        draw_sidebar(rt, s_dcbrush, w * 96.f / dpi, h * 96.f / dpi, (float)dpi);
        double te = now_ms();
        C.last_draw_ms = te - tb;
        hr = ID2D1RenderTarget_EndDraw(rt, NULL, NULL);
        double de = now_ms() - te;
        C.last_enddraw_ms = de;
        if (de > C.enddraw_max_ms) C.enddraw_max_ms = de;
    }
    if (g_inject > 0) {
        g_inject--;
        hr = D2DERR_RECREATE_TARGET;
    }
    C.last_hr = hr;
    if (hr == D2DERR_RECREATE_TARGET) {
        dcrt_discard();
        C.sb_recreate++;
        InvalidateRect(g_top, r, FALSE);
        return;  // keep the old pixels on screen; repaint on the next WM_PAINT
    }
    BitBlt(target, r->left, r->top, w, h, d_memdc, 0, 0, SRCCOPY);
    C.dc_frames++;
    stats_frame(now_ms() - t0);
}

// ---------------------------------------------------------------------------
// Sidebar child: render entry point for HWND RT and flip modes
// ---------------------------------------------------------------------------

static void sb_discard(void) {
    if (cfg.mode == MODE_HWNDRT) hrt_discard();
    else if (cfg.mode == MODE_FLIP) flip_discard();
}

static void sb_render(void) {
    if (!g_sb) return;
    RECT rc;
    GetClientRect(g_sb, &rc);
    if (rc.right <= 0 || rc.bottom <= 0) return;
    double t0 = now_ms();
    UINT dpi = dpi_for(g_sb);
    HRESULT hr = S_OK;
    ID2D1RenderTarget *rt = NULL;
    ID2D1SolidColorBrush *br = NULL;
    if (cfg.mode == MODE_HWNDRT) {
        if (!s_hrt) hr = hrt_create();
        if (FAILED(hr)) {
            jlog("{\"t\":\"error\",\"what\":\"CreateHwndRenderTarget\",\"hr\":\"0x%08lX\"}", (unsigned long)hr);
            return;
        }
        // Size can lag (e.g. first paint after WM_SIZE in async mode): keep in sync.
        if ((LONG)s_hrt_w != rc.right || (LONG)s_hrt_h != rc.bottom) {
            D2D1_SIZE_U ps = {(UINT32)rc.right, (UINT32)rc.bottom};
            ID2D1HwndRenderTarget_Resize(s_hrt, &ps);
            s_hrt_w = (UINT)rc.right;
            s_hrt_h = (UINT)rc.bottom;
        }
        rt = (ID2D1RenderTarget *)s_hrt;
        br = s_brush;
    } else if (cfg.mode == MODE_FLIP) {
        if (!f_sc) hr = flip_create();
        if (FAILED(hr)) {
            jlog("{\"t\":\"error\",\"what\":\"flip_create\",\"hr\":\"0x%08lX\"}", (unsigned long)hr);
            return;
        }
        rt = (ID2D1RenderTarget *)f_dc;
        br = f_brush;
    } else {
        return;
    }
    if (dpi != s_rt_dpi) {
        ID2D1RenderTarget_SetDpi(rt, (FLOAT)dpi, (FLOAT)dpi);
        s_rt_dpi = dpi;
    }
    double tb = now_ms();
    ID2D1RenderTarget_BeginDraw(rt);
    draw_sidebar(rt, br, rc.right * 96.f / dpi, rc.bottom * 96.f / dpi, (float)dpi);
    double te = now_ms();
    C.last_draw_ms = te - tb;
    hr = ID2D1RenderTarget_EndDraw(rt, NULL, NULL);
    if (cfg.mode == MODE_FLIP && SUCCEEDED(hr)) {
        HRESULT ph = IDXGISwapChain1_Present(f_sc, cfg.flip_vsync ? 1 : 0, 0);
        if (ph == DXGI_ERROR_DEVICE_REMOVED || ph == DXGI_ERROR_DEVICE_RESET) hr = D2DERR_RECREATE_TARGET;
        else if (FAILED(ph)) hr = ph;
    }
    double de = now_ms() - te;
    C.last_enddraw_ms = de;
    if (de > C.enddraw_max_ms) C.enddraw_max_ms = de;
    if (g_inject > 0) {
        g_inject--;
        hr = D2DERR_RECREATE_TARGET;  // simulated device loss
    }
    C.last_hr = hr;
    if (hr == D2DERR_RECREATE_TARGET) {
        // Device lost: drop every device-dependent resource (RT, brushes,
        // bitmaps); keep the factory, DWrite formats and text layouts.
        sb_discard();
        C.sb_recreate++;
        InvalidateRect(g_sb, NULL, FALSE);
        return;
    }
    if (FAILED(hr)) jlog("{\"t\":\"error\",\"what\":\"EndDraw\",\"hr\":\"0x%08lX\"}", (unsigned long)hr);
    g_rendered_version = g_content_version;
    g_rendered_w = rc.right;
    g_rendered_h = rc.bottom;
    g_rendered_dpi = dpi;
    stats_frame(now_ms() - t0);
}

// WM_PRINTCLIENT: render the same content through a DC render target so
// WM_PRINT-based capture (PrintWindow without PW_RENDERFULLCONTENT) works.
static void sb_printclient(HDC hdc) {
    RECT rc;
    GetClientRect(g_sb, &rc);
    UINT dpi = dpi_for(g_sb);
    D2D1_RENDER_TARGET_PROPERTIES p;
    memset(&p, 0, sizeof(p));
    p.type = D2D1_RENDER_TARGET_TYPE_DEFAULT;
    p.pixelFormat.format = DXGI_FORMAT_B8G8R8A8_UNORM;
    p.pixelFormat.alphaMode = D2D1_ALPHA_MODE_IGNORE;
    p.dpiX = p.dpiY = (FLOAT)dpi;
    ID2D1DCRenderTarget *dc = NULL;
    ID2D1SolidColorBrush *br = NULL;
    if (FAILED(ID2D1Factory_CreateDCRenderTarget((ID2D1Factory *)g_d2f, &p, &dc))) return;
    D2D1_COLOR_F c = {1, 1, 1, 1};
    if (SUCCEEDED(ID2D1RenderTarget_CreateSolidColorBrush((ID2D1RenderTarget *)dc, &c, NULL, &br)) &&
        SUCCEEDED(ID2D1DCRenderTarget_BindDC(dc, hdc, &rc))) {
        ID2D1RenderTarget_BeginDraw((ID2D1RenderTarget *)dc);
        draw_sidebar((ID2D1RenderTarget *)dc, br, rc.right * 96.f / dpi, rc.bottom * 96.f / dpi, (float)dpi);
        ID2D1RenderTarget_EndDraw((ID2D1RenderTarget *)dc, NULL, NULL);
    }
    if (br) ID2D1SolidColorBrush_Release(br);
    ID2D1DCRenderTarget_Release(dc);
    C.sb_printclient++;
}

static LRESULT CALLBACK sb_proc(HWND h, UINT m, WPARAM wp, LPARAM lp) {
    switch (m) {
    case WM_ERASEBKGND:
        return 1;  // never let DefWindowProc erase: that is the classic flash
    case WM_SIZE: {
        C.sb_size++;
        UINT w = LOWORD(lp), hh = HIWORD(lp);
        if (cfg.mode == MODE_HWNDRT && s_hrt) {
            D2D1_SIZE_U ps = {w, hh};
            HRESULT hr = ID2D1HwndRenderTarget_Resize(s_hrt, &ps);
            s_hrt_w = w;
            s_hrt_h = hh;
            if (hr == D2DERR_RECREATE_TARGET) hrt_discard();
        } else if (cfg.mode == MODE_FLIP) {
            flip_resize(w, hh);
        }
        if (cfg.sync_paint) {
            sb_render();
            ValidateRect(h, NULL);  // drop the WM_PAINT the move queued
        } else {
            InvalidateRect(h, NULL, FALSE);
        }
        return 0;
    }
    case WM_PAINT: {
        if (g_freeze) {
            HRGN r = CreateRectRgn(0, 0, 0, 0);
            GetUpdateRgn(h, r, FALSE);
            CombineRgn(g_frozen_sb, g_frozen_sb, r, RGN_OR);
            DeleteObject(r);
            ValidateRect(h, NULL);
            g_frozen_paints++;
            return 0;
        }
        C.sb_paint++;
        PAINTSTRUCT ps;
        HDC pdc = BeginPaint(h, &ps);
        RECT rc;
        GetClientRect(h, &rc);
        if (g_paint_debug) {
            RECT clip;
            int ck = GetClipBox(pdc, &clip);
            jlog("{\"t\":\"paintdbg\",\"tag\":\"%s\",\"who\":\"sidebar\",\"rcPaint\":[%ld,%ld,%ld,%ld],\"clipbox_kind\":%d,"
                 "\"clipbox\":[%ld,%ld,%ld,%ld]}",
                 cfg.tag, ps.rcPaint.left, ps.rcPaint.top, ps.rcPaint.right, ps.rcPaint.bottom, ck, clip.left, clip.top,
                 clip.right, clip.bottom);
        }
        // Under DWM the swap chain keeps the whole client; a WM_PAINT that
        // only reflects the move/resize we already rendered for is redundant.
        if (!(cfg.skipclean && g_rendered_version == g_content_version && g_rendered_w == rc.right &&
              g_rendered_h == rc.bottom && g_rendered_dpi == dpi_for(h)))
            sb_render();
        EndPaint(h, &ps);
        return 0;
    }
    case WM_PRINTCLIENT:
        sb_printclient((HDC)wp);
        return 0;
    case S7_WM_DPICHANGED_BEFOREPARENT:
        C.sb_before++;
        seq_add("sb:BEFOREPARENT(dpi=%u) ", real_dpi(h));
        return 0;
    case S7_WM_DPICHANGED_AFTERPARENT:
        C.sb_after++;
        seq_add("sb:AFTERPARENT(dpi=%u) ", real_dpi(h));
        InvalidateRect(h, NULL, FALSE);  // sb_render applies SetDpi lazily
        return 0;
    case WM_NCHITTEST:
        return HTCLIENT;
    }
    return DefWindowProcW(h, m, wp, lp);
}

// ---------------------------------------------------------------------------
// D2D overlay child (z-order probe above GL / WebView2)
// ---------------------------------------------------------------------------

static ID2D1HwndRenderTarget *o_hrt;
static ID2D1SolidColorBrush *o_br;

static void ovl_render(HWND h) {
    if (!o_hrt) {
        if (FAILED(hrt_create_for(h, real_dpi(h), 0, D2D1_PRESENT_OPTIONS_IMMEDIATELY, &o_hrt))) return;
        D2D1_COLOR_F c = {1, 1, 1, 1};
        ID2D1RenderTarget_CreateSolidColorBrush((ID2D1RenderTarget *)o_hrt, &c, NULL, &o_br);
    }
    RECT rc;
    GetClientRect(h, &rc);
    D2D1_SIZE_U ps = {(UINT32)rc.right, (UINT32)rc.bottom};
    ID2D1HwndRenderTarget_Resize(o_hrt, &ps);
    ID2D1RenderTarget *rt = (ID2D1RenderTarget *)o_hrt;
    ID2D1RenderTarget_BeginDraw(rt);
    D2D1_COLOR_F c = colf(COL_OVL);
    ID2D1RenderTarget_Clear(rt, &c);
    HRESULT hr = ID2D1RenderTarget_EndDraw(rt, NULL, NULL);
    if (hr == D2DERR_RECREATE_TARGET) {
        ID2D1SolidColorBrush_Release(o_br);
        ID2D1HwndRenderTarget_Release(o_hrt);
        o_br = NULL;
        o_hrt = NULL;
    }
}

static LRESULT CALLBACK ovl_proc(HWND h, UINT m, WPARAM wp, LPARAM lp) {
    switch (m) {
    case WM_ERASEBKGND:
        return 1;
    case WM_SIZE:
        ovl_render(h);
        ValidateRect(h, NULL);
        return 0;
    case WM_PAINT: {
        PAINTSTRUCT ps;
        BeginPaint(h, &ps);
        ovl_render(h);
        EndPaint(h, &ps);
        return 0;
    }
    }
    return DefWindowProcW(h, m, wp, lp);
}

// ---------------------------------------------------------------------------
// OpenGL child: WGL context rendered from its own thread (like Ghostty)
// ---------------------------------------------------------------------------

typedef struct {
    HWND hwnd;
    HDC hdc;
    HGLRC glrc;
    volatile LONG w, h;
    HANDLE thread, wake, frame;
    volatile LONG stop, frames;
    int idx;
} GLPane;
static GLPane g_glp[2];

static DWORD WINAPI gl_thread(void *arg) {
    GLPane *g = (GLPane *)arg;
    if (!wglMakeCurrent(g->hdc, g->glrc)) {
        jlog("{\"t\":\"error\",\"what\":\"wglMakeCurrent\",\"gle\":%lu}", GetLastError());
        return 1;
    }
    jlog("{\"t\":\"gl_info\",\"pane\":%d,\"vendor\":\"%s\",\"renderer\":\"%s\",\"version\":\"%s\"}", g->idx,
         (const char *)glGetString(GL_VENDOR), (const char *)glGetString(GL_RENDERER),
         (const char *)glGetString(GL_VERSION));
    double swap_max = 0, swap_sum = 0;
    while (!g->stop) {
        WaitForSingleObject(g->wake, 16);
        int w = g->w, h = g->h;
        if (w <= 0 || h <= 0) continue;
        glViewport(0, 0, w, h);
        glDisable(GL_SCISSOR_TEST);
        glClearColor(COL_GL.r / 255.f, COL_GL.g / 255.f, COL_GL.b / 255.f, 1.f);
        glClear(GL_COLOR_BUFFER_BIT);
        glEnable(GL_SCISSOR_TEST);
        glScissor(0, 0, 3, h);
        glClearColor(COL_GLMARK.r / 255.f, COL_GLMARK.g / 255.f, COL_GLMARK.b / 255.f, 1.f);
        glClear(GL_COLOR_BUFFER_BIT);
        glDisable(GL_SCISSOR_TEST);
        if (g->frames == 10 || g->frames == 100) {
            unsigned char px[4] = {0, 0, 0, 0};
            glReadPixels(w / 2, h / 2, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, px);
            jlog("{\"t\":\"gl_readback\",\"pane\":%d,\"frame\":%ld,\"center_rgba\":[%u,%u,%u,%u],\"glerr\":%u,"
                 "\"swap_ms_mean\":%.2f,\"swap_ms_max\":%.2f}",
                 g->idx, g->frames, px[0], px[1], px[2], px[3], glGetError(),
                 g->frames ? swap_sum / g->frames : 0.0, swap_max);
        }
        double ts = now_ms();
        BOOL sb_ok = SwapBuffers(g->hdc);
        double tsd = now_ms() - ts;
        swap_sum += tsd;
        if (tsd > swap_max) swap_max = tsd;
        if (!sb_ok && g->frames < 3) jlog("{\"t\":\"error\",\"what\":\"SwapBuffers\",\"pane\":%d,\"gle\":%lu}", g->idx, GetLastError());
        InterlockedIncrement(&g->frames);
        SetEvent(g->frame);
    }
    wglMakeCurrent(NULL, NULL);
    return 0;
}

static HBRUSH g_br_gl, g_br_parent, g_br_tab, g_br_div, g_br_wvhost;

static LRESULT CALLBACK gl_proc(HWND h, UINT m, WPARAM wp, LPARAM lp) {
    GLPane *g = (GLPane *)GetWindowLongPtrW(h, GWLP_USERDATA);
    switch (m) {
    case WM_ERASEBKGND: {
        RECT rc;
        GetClientRect(h, &rc);
        FillRect((HDC)wp, &rc, g_br_gl);  // wmux fills with the terminal bg here
        return 1;
    }
    case WM_PAINT:
        ValidateRect(h, NULL);
        if (g) SetEvent(g->wake);
        return 0;
    case WM_SIZE:
        if (g) {
            g->w = LOWORD(lp);
            g->h = HIWORD(lp);
            ResetEvent(g->frame);
            SetEvent(g->wake);
            if (cfg.gl_wait && g_in_storm) WaitForSingleObject(g->frame, 16);
        }
        return 0;
    case WM_NCHITTEST:
        return HTCLIENT;
    }
    return DefWindowProcW(h, m, wp, lp);
}

static int gl_init(GLPane *g) {
    g->hdc = GetDC(g->hwnd);
    PIXELFORMATDESCRIPTOR pfd;
    memset(&pfd, 0, sizeof(pfd));
    pfd.nSize = sizeof(pfd);
    pfd.nVersion = 1;
    pfd.dwFlags = PFD_DRAW_TO_WINDOW | PFD_SUPPORT_OPENGL | PFD_DOUBLEBUFFER;
    pfd.iPixelType = PFD_TYPE_RGBA;
    pfd.cColorBits = 32;
    pfd.cAlphaBits = 8;
    pfd.cDepthBits = 24;
    pfd.cStencilBits = 8;
    int fmt = ChoosePixelFormat(g->hdc, &pfd);
    if (!fmt || !SetPixelFormat(g->hdc, fmt, &pfd)) return 0;
    g->glrc = wglCreateContext(g->hdc);
    if (!g->glrc) return 0;
    RECT rc;
    GetClientRect(g->hwnd, &rc);
    g->w = rc.right;
    g->h = rc.bottom;
    g->wake = CreateEventW(NULL, FALSE, FALSE, NULL);
    g->frame = CreateEventW(NULL, TRUE, FALSE, NULL);
    g->thread = CreateThread(NULL, 0, gl_thread, g, 0, NULL);
    return 1;
}

static void gl_stop(GLPane *g) {
    if (!g->thread) return;
    g->stop = 1;
    SetEvent(g->wake);
    WaitForSingleObject(g->thread, 2000);
    CloseHandle(g->thread);
    g->thread = NULL;
    if (g->glrc) wglDeleteContext(g->glrc);
    g->glrc = NULL;
}

// ---------------------------------------------------------------------------
// WebView2 (minimal C COM declarations; slot order from WebView2.idl)
// ---------------------------------------------------------------------------

DEFINE_GUID(S7_IID_EnvCompleted, 0x4e8a3389, 0xc9d8, 0x4bd2, 0xb6, 0xb5, 0x12, 0x4f, 0xee, 0x6c, 0xc1, 0x4d);
DEFINE_GUID(S7_IID_CtlCompleted, 0x6c4819f3, 0xc9b7, 0x4260, 0x81, 0x27, 0xc9, 0xf5, 0xbd, 0xe7, 0xf6, 0x8c);
DEFINE_GUID(S7_IID_NavCompleted, 0xd33a35bf, 0x1c49, 0x4f98, 0x93, 0xab, 0x00, 0x6e, 0x05, 0x33, 0xfe, 0x1c);

typedef struct WV2View WV2View;
typedef struct WV2Ctl WV2Ctl;
typedef struct WV2Env WV2Env;
typedef struct { INT64 value; } EvtToken;

typedef struct {
    void *QueryInterface;
    ULONG(STDMETHODCALLTYPE *AddRef)(WV2Env *);
    ULONG(STDMETHODCALLTYPE *Release)(WV2Env *);
    HRESULT(STDMETHODCALLTYPE *CreateCoreWebView2Controller)(WV2Env *, HWND, void *);  // 3
} WV2EnvVtbl;
struct WV2Env { const WV2EnvVtbl *lpVtbl; };

typedef struct {
    void *QueryInterface;
    ULONG(STDMETHODCALLTYPE *AddRef)(WV2Ctl *);
    ULONG(STDMETHODCALLTYPE *Release)(WV2Ctl *);
    HRESULT(STDMETHODCALLTYPE *get_IsVisible)(WV2Ctl *, BOOL *);  // 3
    HRESULT(STDMETHODCALLTYPE *put_IsVisible)(WV2Ctl *, BOOL);    // 4
    HRESULT(STDMETHODCALLTYPE *get_Bounds)(WV2Ctl *, RECT *);     // 5
    HRESULT(STDMETHODCALLTYPE *put_Bounds)(WV2Ctl *, RECT);       // 6
    void *pad7_22[16];                                            // 7..22
    HRESULT(STDMETHODCALLTYPE *NotifyParentWindowPositionChanged)(WV2Ctl *);  // 23
    HRESULT(STDMETHODCALLTYPE *Close)(WV2Ctl *);                              // 24
    HRESULT(STDMETHODCALLTYPE *get_CoreWebView2)(WV2Ctl *, WV2View **);       // 25
} WV2CtlVtbl;
struct WV2Ctl { const WV2CtlVtbl *lpVtbl; };

typedef struct {
    void *QueryInterface;
    ULONG(STDMETHODCALLTYPE *AddRef)(WV2View *);
    ULONG(STDMETHODCALLTYPE *Release)(WV2View *);
    void *get_Settings;                                                // 3
    void *get_Source;                                                  // 4
    HRESULT(STDMETHODCALLTYPE *Navigate)(WV2View *, LPCWSTR);          // 5
    HRESULT(STDMETHODCALLTYPE *NavigateToString)(WV2View *, LPCWSTR);  // 6
    void *pad7_14[8];                                                  // 7..14
    HRESULT(STDMETHODCALLTYPE *add_NavigationCompleted)(WV2View *, void *, EvtToken *);  // 15
} WV2ViewVtbl;
struct WV2View { const WV2ViewVtbl *lpVtbl; };

// One generic handler object: QI/AddRef/Release + Invoke(this, a, b).
typedef struct Handler Handler;
typedef struct {
    HRESULT(STDMETHODCALLTYPE *QueryInterface)(Handler *, REFIID, void **);
    ULONG(STDMETHODCALLTYPE *AddRef)(Handler *);
    ULONG(STDMETHODCALLTYPE *Release)(Handler *);
    HRESULT(STDMETHODCALLTYPE *Invoke)(Handler *, void *, void *);
} HandlerVtbl;
struct Handler {
    const HandlerVtbl *lpVtbl;
    LONG ref;
    const GUID *iid;
};

static WV2Env *g_wvenv;
static WV2Ctl *g_wvctl;
static WV2View *g_wvview;
static int g_wv_state;  // 0 none, 1 env, 2 ctl, 3 nav done, -1 failed
static double g_wv_t0, g_wv_t_nav;

static HRESULT STDMETHODCALLTYPE h_qi(Handler *h, REFIID riid, void **out) {
    if (IsEqualGUID(riid, &IID_IUnknown) || IsEqualGUID(riid, h->iid)) {
        *out = h;
        InterlockedIncrement(&h->ref);
        return S_OK;
    }
    *out = NULL;
    return E_NOINTERFACE;
}
static ULONG STDMETHODCALLTYPE h_addref(Handler *h) { return (ULONG)InterlockedIncrement(&h->ref); }
static ULONG STDMETHODCALLTYPE h_release(Handler *h) { return (ULONG)InterlockedDecrement(&h->ref); }  // static objects

static HRESULT STDMETHODCALLTYPE nav_invoke(Handler *h, void *sender, void *args) {
    (void)h;
    (void)sender;
    (void)args;
    g_wv_state = 3;
    g_wv_t_nav = now_ms() - g_wv_t0;
    return S_OK;
}
static const HandlerVtbl NAV_VT = {h_qi, h_addref, h_release, nav_invoke};
static Handler g_nav_handler = {&NAV_VT, 1, &S7_IID_NavCompleted};

static const wchar_t *WV_HTML =
    L"<!doctype html><html><body style=\"margin:0;background:#0080C0;color:#fff;font:20px Segoe UI\">"
    L"<div style=\"position:fixed;left:0;top:0;bottom:0;width:3px;background:#FF8000\"></div>"
    L"<div style=\"padding:16px 24px\">WebView2 sibling pane</div></body></html>";

static HRESULT STDMETHODCALLTYPE ctl_invoke(Handler *h, void *hrv, void *ctl) {
    (void)h;
    HRESULT hr = (HRESULT)(INT_PTR)hrv;
    if (FAILED(hr) || !ctl) {
        jlog("{\"t\":\"wv2\",\"tag\":\"%s\",\"stage\":\"controller\",\"hr\":\"0x%08lX\"}", cfg.tag, (unsigned long)hr);
        g_wv_state = -1;
        return S_OK;
    }
    g_wvctl = (WV2Ctl *)ctl;
    g_wvctl->lpVtbl->AddRef(g_wvctl);
    g_wv_state = 2;
    RECT rc;
    GetClientRect(g_wvhost, &rc);
    g_wvctl->lpVtbl->put_Bounds(g_wvctl, rc);
    g_wvctl->lpVtbl->put_IsVisible(g_wvctl, TRUE);
    if (SUCCEEDED(g_wvctl->lpVtbl->get_CoreWebView2(g_wvctl, &g_wvview)) && g_wvview) {
        EvtToken tok;
        g_wvview->lpVtbl->add_NavigationCompleted(g_wvview, &g_nav_handler, &tok);
        g_wvview->lpVtbl->NavigateToString(g_wvview, WV_HTML);
    }
    return S_OK;
}
static const HandlerVtbl CTL_VT = {h_qi, h_addref, h_release, ctl_invoke};
static Handler g_ctl_handler = {&CTL_VT, 1, &S7_IID_CtlCompleted};

static HRESULT STDMETHODCALLTYPE env_invoke(Handler *h, void *hrv, void *env) {
    (void)h;
    HRESULT hr = (HRESULT)(INT_PTR)hrv;
    if (FAILED(hr) || !env) {
        jlog("{\"t\":\"wv2\",\"tag\":\"%s\",\"stage\":\"environment\",\"hr\":\"0x%08lX\"}", cfg.tag, (unsigned long)hr);
        g_wv_state = -1;
        return S_OK;
    }
    g_wvenv = (WV2Env *)env;
    g_wvenv->lpVtbl->AddRef(g_wvenv);
    g_wv_state = 1;
    hr = g_wvenv->lpVtbl->CreateCoreWebView2Controller(g_wvenv, g_wvhost, &g_ctl_handler);
    if (FAILED(hr)) {
        jlog("{\"t\":\"wv2\",\"tag\":\"%s\",\"stage\":\"CreateController\",\"hr\":\"0x%08lX\"}", cfg.tag, (unsigned long)hr);
        g_wv_state = -1;
    }
    return S_OK;
}
static const HandlerVtbl ENV_VT = {h_qi, h_addref, h_release, env_invoke};
static Handler g_env_handler = {&ENV_VT, 1, &S7_IID_EnvCompleted};

typedef HRESULT(STDAPICALLTYPE *PFN_CreateEnv)(LPCWSTR, LPCWSTR, void *, void *);

static void wv_start(void) {
    wchar_t exe[MAX_PATH], dll[MAX_PATH];
    GetModuleFileNameW(NULL, exe, MAX_PATH);
    wchar_t *slash = wcsrchr(exe, L'\\');
    if (slash) slash[1] = 0;
    swprintf(dll, MAX_PATH, L"%lsWebView2Loader.dll", exe);
    HMODULE m = LoadLibraryW(dll);
    if (!m) {
        jlog("{\"t\":\"wv2\",\"stage\":\"loader\",\"error\":\"WebView2Loader.dll not found\"}");
        g_wv_state = -1;
        return;
    }
    PFN_CreateEnv create = (PFN_CreateEnv)(void *)GetProcAddress(m, "CreateCoreWebView2EnvironmentWithOptions");
    if (!create) {
        g_wv_state = -1;
        return;
    }
    if (cfg.occl_off)
        SetEnvironmentVariableW(L"WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS",
                                L"--disable-features=CalculateNativeWinOcclusion");
    wchar_t udf[MAX_PATH];
    swprintf(udf, MAX_PATH, L"%hs\\wv2data-%hs", cfg.out, cfg.tag);
    g_wv_t0 = now_ms();
    HRESULT hr = create(NULL, udf, NULL, &g_env_handler);
    if (FAILED(hr)) {
        jlog("{\"t\":\"wv2\",\"tag\":\"%s\",\"stage\":\"CreateEnvironment\",\"hr\":\"0x%08lX\"}", cfg.tag, (unsigned long)hr);
        g_wv_state = -1;
    }
}

static void wv_stop(void) {
    if (g_wvview) g_wvview->lpVtbl->Release(g_wvview);
    if (g_wvctl) {
        g_wvctl->lpVtbl->Close(g_wvctl);
        g_wvctl->lpVtbl->Release(g_wvctl);
    }
    if (g_wvenv) g_wvenv->lpVtbl->Release(g_wvenv);
    g_wvview = NULL;
    g_wvctl = NULL;
    g_wvenv = NULL;
}

static LRESULT CALLBACK wvhost_proc(HWND h, UINT m, WPARAM wp, LPARAM lp) {
    switch (m) {
    case WM_SIZE:
        if (g_wvctl) {
            RECT b = {0, 0, LOWORD(lp), HIWORD(lp)};
            g_wvctl->lpVtbl->put_Bounds(g_wvctl, b);
        }
        return 0;
    case WM_ERASEBKGND: {
        RECT rc;
        GetClientRect(h, &rc);
        FillRect((HDC)wp, &rc, g_br_wvhost);
        return 1;
    }
    }
    return DefWindowProcW(h, m, wp, lp);
}

// ---------------------------------------------------------------------------
// Top-level window
// ---------------------------------------------------------------------------

static void parent_paint(HWND h) {
    C.top_paint++;
    PAINTSTRUCT ps;
    HDC dc = BeginPaint(h, &ps);
    RECT c;
    GetClientRect(h, &c);
    int save = SaveDC(dc);
    if (cfg.mode == MODE_DCRT) ExcludeClipRect(dc, g_L.sb.left, g_L.sb.top, g_L.sb.right, g_L.sb.bottom);
    FillRect(dc, &c, g_br_parent);  // WS_CLIPCHILDREN keeps this off the children
    FillRect(dc, &g_L.tab, g_br_tab);
    FillRect(dc, &g_L.div1, g_br_div);
    if (!IsRectEmpty(&g_L.div2)) FillRect(dc, &g_L.div2, g_br_div);
    RestoreDC(dc, save);
    if (g_paint_debug) {
        RECT clip;
        int ck = GetClipBox(dc, &clip);
        jlog("{\"t\":\"paintdbg\",\"tag\":\"%s\",\"who\":\"top\",\"rcPaint\":[%ld,%ld,%ld,%ld],\"clipbox_kind\":%d,"
             "\"clipbox\":[%ld,%ld,%ld,%ld]}",
             cfg.tag, ps.rcPaint.left, ps.rcPaint.top, ps.rcPaint.right, ps.rcPaint.bottom, ck, clip.left, clip.top,
             clip.right, clip.bottom);
    }
    // Like wmux's paintChrome: paint the sidebar unconditionally. (Do not gate
    // on ps.rcPaint: for an off-screen top-level BeginPaint returns an empty
    // rcPaint and an empty clip box, so a gated paint would never run there.)
    if (cfg.mode == MODE_DCRT) dcrt_paint(dc, &g_L.sb);
    EndPaint(h, &ps);
}

static LRESULT CALLBACK top_proc(HWND h, UINT m, WPARAM wp, LPARAM lp) {
    switch (m) {
    case WM_ERASEBKGND:
        return 1;  // wmux: Window.zig WM_ERASEBKGND => return 1
    case WM_SIZE:
        C.top_size++;
        if (!g_top) return 0;
        layout();
        InvalidateRect(h, &g_L.tab, FALSE);
        InvalidateRect(h, &g_L.div1, FALSE);
        InvalidateRect(h, &g_L.div2, FALSE);
        if (cfg.mode == MODE_DCRT) {
            if (cfg.sync_paint) RedrawWindow(h, &g_L.sb, NULL, RDW_INVALIDATE | RDW_UPDATENOW);
            else InvalidateRect(h, &g_L.sb, FALSE);
        }
        return 0;
    case WM_PAINT:
        if (g_freeze) {
            HRGN r = CreateRectRgn(0, 0, 0, 0);
            GetUpdateRgn(h, r, FALSE);
            CombineRgn(g_frozen_top, g_frozen_top, r, RGN_OR);
            DeleteObject(r);
            ValidateRect(h, NULL);
            g_frozen_paints++;
            return 0;
        }
        parent_paint(h);
        return 0;
    case WM_DPICHANGED: {
        C.top_dpichanged++;
        RECT *r = (RECT *)lp;
        seq_add("top:WM_DPICHANGED(wp=%u,sugg=%ld,%ld,%ld,%ld,childdpi=%u) ", (unsigned)LOWORD(wp), r->left, r->top,
                r->right, r->bottom, g_sb ? real_dpi(g_sb) : 0);
        SetWindowPos(h, NULL, r->left, r->top, r->right - r->left, r->bottom - r->top,
                     SWP_NOZORDER | SWP_NOACTIVATE | SWP_NOOWNERZORDER);
        layout();
        RedrawWindow(h, NULL, NULL, RDW_INVALIDATE | RDW_ALLCHILDREN);
        return 0;
    }
    case S7_WM_GETDPISCALEDSIZE:
        C.top_getdpiscaled++;
        seq_add("top:WM_GETDPISCALEDSIZE(%u) ", (unsigned)wp);
        return FALSE;
    case WM_MOVE:
        if (g_wvctl) g_wvctl->lpVtbl->NotifyParentWindowPositionChanged(g_wvctl);
        return 0;
    case WM_MOUSEACTIVATE:
        return MA_NOACTIVATE;
    case WM_APP_RUN: {
        extern void run_tests(void);
        run_tests();
        return 0;
    }
    case WM_CLOSE:
        // Stop GL threads and WebView2 before the HWNDs (and their DCs) die.
        gl_stop(&g_glp[0]);
        gl_stop(&g_glp[1]);
        wv_stop();
        DestroyWindow(h);
        return 0;
    case WM_DESTROY:
        PostQuitMessage(0);
        return 0;
    }
    return DefWindowProcW(h, m, wp, lp);
}

// ---------------------------------------------------------------------------
// Message pumping helpers (tests run inside a posted message, pumping nested)
// ---------------------------------------------------------------------------

static void pump_once(void) {
    MSG msg;
    while (PeekMessageW(&msg, NULL, 0, 0, PM_REMOVE)) {
        if (msg.message == WM_QUIT) {
            PostQuitMessage((int)msg.wParam);
            return;
        }
        TranslateMessage(&msg);
        DispatchMessageW(&msg);
    }
}

static void pump_for(int ms) {
    double end = now_ms() + ms;
    while (now_ms() < end) {
        pump_once();
        MsgWaitForMultipleObjects(0, NULL, FALSE, 2, QS_ALLINPUT);
    }
    pump_once();
}

// Process until the queue holds no input and no WM_PAINT; returns elapsed ms.
static double pump_idle(int max_ms) {
    double t0 = now_ms();
    for (;;) {
        pump_once();
        DWORD qs = GetQueueStatus(QS_ALLINPUT);
        if (HIWORD(qs) == 0) break;
        if (now_ms() - t0 > max_ms) break;
    }
    return now_ms() - t0;
}

static void wait_gl_frames(int n, int max_ms) {
    LONG f0 = g_glp[0].frames;
    double end = now_ms() + max_ms;
    while (g_glp[0].frames - f0 < n && now_ms() < end) pump_for(4);
}

// ---------------------------------------------------------------------------
// Capture + classification
// ---------------------------------------------------------------------------

enum { K_SENT, K_BLACK, K_WHITE, K_PARENT, K_TAB, K_DIV, K_SB, K_SB2, K_SBMARK, K_RULER, K_GL, K_GLMARK, K_GLERASE,
       K_WV, K_WVMARK, K_WVHOST, K_OVL, K_OTHER, K_N };
static const char *KN[K_N] = {"sent", "black", "white", "parent", "tab", "div", "sb", "sb2", "sbmark", "ruler",
                              "gl", "glmark", "glerase", "wv", "wvmark", "wvhost", "ovl", "other"};

typedef struct {
    int w, h;
    DWORD *px;
    HBITMAP bmp;
    HDC dc;
    BOOL ok;
    double ms;
} Cap;

static int near3(BYTE r, BYTE g, BYTE b, RGB3 c, int tol) {
    return abs((int)r - c.r) <= tol && abs((int)g - c.g) <= tol && abs((int)b - c.b) <= tol;
}

static int classify(DWORD p) {
    BYTE b = p & 0xFF, g = (p >> 8) & 0xFF, r = (p >> 16) & 0xFF;
    if (r == 1 && g == 2 && b == 3) return K_SENT;
    if (r <= 4 && g <= 4 && b <= 4) return K_BLACK;
    if (r >= 250 && g >= 250 && b >= 250) return K_WHITE;
    const int t = 6;
    if (near3(r, g, b, COL_PARENT, t)) return K_PARENT;
    if (near3(r, g, b, COL_TAB, t)) return K_TAB;
    if (near3(r, g, b, COL_DIV, t)) return K_DIV;
    if (near3(r, g, b, COL_SB, t)) return K_SB;
    if (near3(r, g, b, COL_SB2, t)) return K_SB2;
    if (near3(r, g, b, COL_SBMARK, t)) return K_SBMARK;
    if (near3(r, g, b, COL_RULER, t)) return K_RULER;
    if (near3(r, g, b, COL_GL, t)) return K_GL;
    if (near3(r, g, b, COL_GLMARK, t)) return K_GLMARK;
    if (near3(r, g, b, COL_GLERASE, t)) return K_GLERASE;
    if (near3(r, g, b, COL_WV, 8)) return K_WV;
    if (near3(r, g, b, COL_WVMARK, 8)) return K_WVMARK;
    if (near3(r, g, b, COL_WVHOST, t)) return K_WVHOST;
    if (near3(r, g, b, COL_OVL, t)) return K_OVL;
    return K_OTHER;
}

static void cap_free(Cap *c) {
    if (c->dc) DeleteDC(c->dc);
    if (c->bmp) DeleteObject(c->bmp);
    memset(c, 0, sizeof(*c));
}

// Capture the client area of `h` (PW_CLIENTONLY is always added).
static BOOL capture(HWND h, UINT flags, Cap *c) {
    memset(c, 0, sizeof(*c));
    RECT rc;
    GetClientRect(h, &rc);
    c->w = rc.right;
    c->h = rc.bottom;
    if (c->w <= 0 || c->h <= 0) return FALSE;
    BITMAPINFO bi;
    memset(&bi, 0, sizeof(bi));
    bi.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
    bi.bmiHeader.biWidth = c->w;
    bi.bmiHeader.biHeight = -c->h;
    bi.bmiHeader.biPlanes = 1;
    bi.bmiHeader.biBitCount = 32;
    bi.bmiHeader.biCompression = BI_RGB;
    HDC scr = GetDC(NULL);
    c->dc = CreateCompatibleDC(scr);
    ReleaseDC(NULL, scr);
    c->bmp = CreateDIBSection(c->dc, &bi, DIB_RGB_COLORS, (void **)&c->px, NULL, 0);
    SelectObject(c->dc, c->bmp);
    for (int i = 0; i < c->w * c->h; i++) c->px[i] = 0x00010203;  // sentinel
    double t0 = now_ms();
    c->ok = PrintWindow(h, c->dc, flags | PW_CLIENTONLY);
    GdiFlush();
    c->ms = now_ms() - t0;
    return c->ok;
}

// PrintWindow(PW_RENDERFULLCONTENT) without letting it service our pending
// WM_PAINTs: shows what DWM has right now; the deferred update regions are
// re-invalidated afterwards so nothing is lost.
static BOOL capture_passive(Cap *c, LONG *frozen) {
    g_frozen_sb = CreateRectRgn(0, 0, 0, 0);
    g_frozen_top = CreateRectRgn(0, 0, 0, 0);
    g_frozen_paints = 0;
    g_freeze = 1;
    BOOL ok = capture(g_top, PW_RENDERFULLCONTENT, c);
    g_freeze = 0;
    if (g_sb) InvalidateRgn(g_sb, g_frozen_sb, FALSE);
    InvalidateRgn(g_top, g_frozen_top, FALSE);
    DeleteObject(g_frozen_sb);
    DeleteObject(g_frozen_top);
    g_frozen_sb = g_frozen_top = NULL;
    if (frozen) *frozen = g_frozen_paints;
    return ok;
}

// Plain GDI read of a window DC (what BitBlt-from-window tools see).
static BOOL capture_bitblt(HWND h, Cap *c) {
    memset(c, 0, sizeof(*c));
    RECT rc;
    GetClientRect(h, &rc);
    c->w = rc.right;
    c->h = rc.bottom;
    BITMAPINFO bi;
    memset(&bi, 0, sizeof(bi));
    bi.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
    bi.bmiHeader.biWidth = c->w;
    bi.bmiHeader.biHeight = -c->h;
    bi.bmiHeader.biPlanes = 1;
    bi.bmiHeader.biBitCount = 32;
    bi.bmiHeader.biCompression = BI_RGB;
    HDC src = GetDC(h);
    c->dc = CreateCompatibleDC(src);
    c->bmp = CreateDIBSection(c->dc, &bi, DIB_RGB_COLORS, (void **)&c->px, NULL, 0);
    SelectObject(c->dc, c->bmp);
    for (int i = 0; i < c->w * c->h; i++) c->px[i] = 0x00010203;
    c->ok = BitBlt(c->dc, 0, 0, c->w, c->h, src, 0, 0, SRCCOPY);
    GdiFlush();
    ReleaseDC(h, src);
    return c->ok;
}

// The top-level's redirection surface through a cache DC without
// DCX_CLIPCHILDREN: shows GDI and blt-model content (HWND RT, DC RT) and
// never sends WM_PAINT/WM_PRINT, so it can observe transient states.
static BOOL capture_view(Cap *c) {
    memset(c, 0, sizeof(*c));
    RECT rc;
    GetClientRect(g_top, &rc);
    c->w = rc.right;
    c->h = rc.bottom;
    if (c->w <= 0 || c->h <= 0) return FALSE;
    BITMAPINFO bi;
    memset(&bi, 0, sizeof(bi));
    bi.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
    bi.bmiHeader.biWidth = c->w;
    bi.bmiHeader.biHeight = -c->h;
    bi.bmiHeader.biPlanes = 1;
    bi.bmiHeader.biBitCount = 32;
    bi.bmiHeader.biCompression = BI_RGB;
    HDC src = GetDCEx(g_top, NULL, DCX_CACHE);
    c->dc = CreateCompatibleDC(src);
    c->bmp = CreateDIBSection(c->dc, &bi, DIB_RGB_COLORS, (void **)&c->px, NULL, 0);
    SelectObject(c->dc, c->bmp);
    for (int i = 0; i < c->w * c->h; i++) c->px[i] = 0x00010203;
    double t0 = now_ms();
    c->ok = BitBlt(c->dc, 0, 0, c->w, c->h, src, 0, 0, SRCCOPY);
    GdiFlush();
    c->ms = now_ms() - t0;
    ReleaseDC(g_top, src);
    return c->ok;
}

typedef struct { int n[K_N]; int total; } Hist;

static void hist(const Cap *c, RECT r, Hist *hs) {
    memset(hs, 0, sizeof(*hs));
    if (!c->px) return;
    if (r.left < 0) r.left = 0;
    if (r.top < 0) r.top = 0;
    if (r.right > c->w) r.right = c->w;
    if (r.bottom > c->h) r.bottom = c->h;
    for (int y = r.top; y < r.bottom; y++)
        for (int x = r.left; x < r.right; x++) {
            hs->n[classify(c->px[y * c->w + x])]++;
            hs->total++;
        }
}

// Pixels that must never appear inside the given region kind. (White and
// divider-gray are excluded for the sidebar: emoji/text AA produce a few.)
static int bad_sidebar(const Hist *h) {
    return h->n[K_SENT] + h->n[K_BLACK] + h->n[K_PARENT] + h->n[K_TAB] + h->n[K_GL] + h->n[K_GLMARK] +
           h->n[K_GLERASE] + h->n[K_WV] + h->n[K_WVMARK] + h->n[K_WVHOST];
}
static int bad_gl(const Hist *h) { return h->total - h->n[K_GL] - h->n[K_GLMARK]; }
// WebView2: host color, black, sentinel and parent mean "not covered yet";
// white beyond the page's own white text (~1k px) means an unpainted surface.
static int bad_wv(const Hist *h) {
    int white = h->n[K_WHITE] > 2000 ? h->n[K_WHITE] - 2000 : 0;
    return h->n[K_WVHOST] + h->n[K_BLACK] + h->n[K_SENT] + h->n[K_PARENT] + h->n[K_GLERASE] + white;
}
static int bad_tab(const Hist *h) { return h->total - h->n[K_TAB]; }

static int hist_json(char *buf, size_t cap, const char *name, const Hist *h) {
    int n = snprintf(buf, cap, "\"%s\":{\"total\":%d", name, h->total);
    for (int k = 0; k < K_N; k++)
        if (h->n[k]) n += snprintf(buf + n, cap - n, ",\"%s\":%d", KN[k], h->n[k]);
    n += snprintf(buf + n, cap - n, "}");
    return n;
}

typedef struct { int sb, gl1, gl2, wv, tab, total; } Bad;

static Bad analyze(const Cap *c, char *json, size_t cap) {
    Bad b;
    memset(&b, 0, sizeof(b));
    Hist hsb, hgl1, hgl2, hwv, htab;
    RECT sb = g_L.sb;
    hist(c, sb, &hsb);
    hist(c, g_L.gl1, &hgl1);
    hist(c, g_L.gl2, &hgl2);
    hist(c, g_L.tab, &htab);
    if (cfg.webview) hist(c, g_L.wv, &hwv);
    else memset(&hwv, 0, sizeof(hwv));
    b.sb = bad_sidebar(&hsb);
    b.gl1 = bad_gl(&hgl1);
    b.gl2 = bad_gl(&hgl2);
    b.wv = cfg.webview ? bad_wv(&hwv) : 0;
    b.tab = bad_tab(&htab);
    b.total = b.sb + b.gl1 + b.wv + b.tab;  // GL2 excluded (never presents off-screen)
    if (json) {
        int n = snprintf(json, cap, "{");
        n += hist_json(json + n, cap - n, "sidebar", &hsb);
        n += snprintf(json + n, cap - n, ",");
        n += hist_json(json + n, cap - n, "gl1", &hgl1);
        n += snprintf(json + n, cap - n, ",");
        n += hist_json(json + n, cap - n, "gl2", &hgl2);
        n += snprintf(json + n, cap - n, ",");
        n += hist_json(json + n, cap - n, "tab", &htab);
        if (cfg.webview) {
            n += snprintf(json + n, cap - n, ",");
            n += hist_json(json + n, cap - n, "wv", &hwv);
        }
        snprintf(json + n, cap - n, ",\"bad\":{\"sb\":%d,\"gl1\":%d,\"gl2\":%d,\"wv\":%d,\"tab\":%d}}", b.sb, b.gl1,
                 b.gl2, b.wv, b.tab);
    }
    return b;
}

static void save_bmp(const Cap *c, const char *name) {
    if (!c->px) return;
    char path[MAX_PATH];
    snprintf(path, sizeof(path), "%s\\%s-%s.bmp", cfg.out, cfg.tag, name);
    FILE *f = fopen(path, "wb");
    if (!f) return;
    BITMAPFILEHEADER fh;
    BITMAPINFOHEADER ih;
    memset(&fh, 0, sizeof(fh));
    memset(&ih, 0, sizeof(ih));
    DWORD sz = (DWORD)(c->w * c->h * 4);
    fh.bfType = 0x4D42;
    fh.bfOffBits = sizeof(fh) + sizeof(ih);
    fh.bfSize = fh.bfOffBits + sz;
    ih.biSize = sizeof(ih);
    ih.biWidth = c->w;
    ih.biHeight = -c->h;
    ih.biPlanes = 1;
    ih.biBitCount = 32;
    ih.biCompression = BI_RGB;
    fwrite(&fh, sizeof(fh), 1, f);
    fwrite(&ih, sizeof(ih), 1, f);
    fwrite(c->px, sz, 1, f);
    fclose(f);
}

// Vertical run of ruler pixels in the sidebar (expected 100 DIP * scale).
static int ruler_px(const Cap *c, UINT dpi) {
    int x = g_L.sb.left + (int)(4.f * dpi / 96.f);
    int best = 0, run = 0;
    for (int y = 0; y < c->h && y < g_L.sb.bottom; y++) {
        if (classify(c->px[y * c->w + x]) == K_RULER) {
            run++;
            if (run > best) best = run;
        } else run = 0;
    }
    return best;
}

// Ink extent (rows containing text-like pixels) of row `i`'s title band.
static int title_ink_px(const Cap *c, int row, UINT dpi) {
    float s = dpi / 96.f, y = ROW0_Y;
    for (int i = 0; i < row; i++) y += row_height(i);
    int y0 = (int)((y + 4.f) * s), y1 = (int)((y + 26.f) * s);
    int x0 = (int)(16.f * s), x1 = g_L.sb.right - (int)(60.f * s);
    int top = -1, bot = -1;
    for (int yy = y0; yy < y1 && yy < c->h; yy++)
        for (int xx = x0; xx < x1; xx++) {
            int k = classify(c->px[yy * c->w + xx]);
            if (k == K_OTHER || k == K_WHITE) {
                if (top < 0) top = yy;
                bot = yy;
                break;
            }
        }
    return top < 0 ? 0 : bot - top + 1;
}

// Saturated (colorful) pixels in a row's title band: color emoji evidence.
static int color_px(const Cap *c, int row, UINT dpi) {
    float s = dpi / 96.f, y = ROW0_Y;
    for (int i = 0; i < row; i++) y += row_height(i);
    int y0 = (int)((y + 4.f) * s), y1 = (int)((y + 26.f) * s);
    int x0 = (int)(16.f * s), x1 = g_L.sb.right - (int)(60.f * s);
    int n = 0;
    for (int yy = y0; yy < y1 && yy < c->h; yy++)
        for (int xx = x0; xx < x1; xx++) {
            DWORD p = c->px[yy * c->w + xx];
            int b = p & 0xFF, g = (p >> 8) & 0xFF, r = (p >> 16) & 0xFF;
            int mx = r > g ? (r > b ? r : b) : (g > b ? g : b);
            int mn = r < g ? (r < b ? r : b) : (g < b ? g : b);
            if (mx - mn > 90 && classify(p) == K_OTHER) n++;
        }
    return n;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

static char g_json[65536];

static void settle(void) {
    pump_idle(500);
    wait_gl_frames(2, 200);
    pump_idle(200);
}

static void cfg_json(char *buf, size_t cap) {
    snprintf(buf, cap,
             "{\"mode\":\"%s\",\"present\":%d,\"sync_paint\":%d,\"defer\":%d,\"webview\":%d,\"clip\":%d,"
             "\"layered\":%d,\"sw_dcrt\":%d,\"sw_hwndrt\":%d,\"flip_none\":%d,\"flip_vsync\":%d,\"gl_wait\":%d,"
             "\"occl_off\":%d,\"nocopy\":%d}",
             MODE_NAMES[cfg.mode], cfg.present, cfg.sync_paint, cfg.defer, cfg.webview, cfg.clip, cfg.layered,
             cfg.sw_dcrt, cfg.sw_hwndrt, cfg.flip_none, cfg.flip_vsync, cfg.gl_wait, cfg.occl_off, cfg.nocopy);
}

static int want(const char *name) {
    if (strcmp(cfg.tests, "all") == 0) return strcmp(name, "abi_broken") != 0;
    char tmp[600];
    snprintf(tmp, sizeof(tmp), ",%s,", cfg.tests);
    char key[64];
    snprintf(key, sizeof(key), ",%s,", name);
    return strstr(tmp, key) != NULL;
}

static void zorder_json(char *buf, size_t cap) {
    int n = snprintf(buf, cap, "[");
    int first = 1;
    for (HWND w = GetWindow(g_top, GW_CHILD); w; w = GetWindow(w, GW_HWNDNEXT)) {
        wchar_t cls[64];
        GetClassNameW(w, cls, 64);
        n += snprintf(buf + n, cap - n, "%s\"%s:%ls:clip=%d\"", first ? "" : ",", tag_of(w), cls,
                      (GetWindowLongPtrW(w, GWL_STYLE) & WS_CLIPSIBLINGS) ? 1 : 0);
        first = 0;
    }
    snprintf(buf + n, cap - n, "]");
}

static void marker_check(const Cap *c, int *missing, int *stale);

static void capture_report(const char *how, Cap *c, const char *bmpname) {
    char cj[512], zj[1024];
    cfg_json(cj, sizeof(cj));
    zorder_json(zj, sizeof(zj));
    Bad b = analyze(c, g_json, sizeof(g_json));
    UINT dpi = dpi_for(g_top);
    int miss, stale;
    marker_check(c, &miss, &stale);
    jlog("{\"t\":\"capture\",\"tag\":\"%s\",\"how\":\"%s\",\"cfg\":%s,\"ok\":%d,\"ms\":%.2f,\"w\":%d,\"h\":%d,"
         "\"dpi\":%u,\"bad_total\":%d,\"marker_missing\":%d,\"marker_stale\":%d,\"ruler_px\":%d,"
         "\"emoji_color_px\":%d,\"emoji_control_px\":%d,\"printclient_calls\":%ld,\"zorder\":%s,\"regions\":%s}",
         cfg.tag, how, cj, c->ok, c->ms, c->w, c->h, dpi, b.total, miss, stale, ruler_px(c, dpi),
         color_px(c, 2, dpi), color_px(c, 5, dpi), C.sb_printclient, zj, g_json);
    if (bmpname) save_bmp(c, bmpname);
}

static void child_report(const char *how, HWND h, Cap *c) {
    Hist hs;
    RECT r = {0, 0, c->w, c->h};
    hist(c, r, &hs);
    hist_json(g_json, sizeof(g_json), "h", &hs);
    jlog("{\"t\":\"capture_child\",\"tag\":\"%s\",\"child\":\"%s\",\"how\":\"%s\",\"ok\":%d,\"ms\":%.2f,%s}", cfg.tag,
         tag_of(h), how, c->ok, c->ms, g_json);
}

static void test_capture(void) {
    settle();
    Cap c;
    capture(g_top, 0, &c);
    capture_report("PrintWindow(top,PW_CLIENTONLY) #1", &c, "baseline-pw0");
    cap_free(&c);
    capture(g_top, 0, &c);
    capture_report("PrintWindow(top,PW_CLIENTONLY) #2", &c, NULL);
    cap_free(&c);
    capture(g_top, PW_RENDERFULLCONTENT, &c);
    capture_report("PrintWindow(top,PW_RENDERFULLCONTENT|PW_CLIENTONLY)", &c, "baseline-prf");
    cap_free(&c);
    capture_view(&c);
    capture_report("BitBlt(GetDCEx(top,DCX_CACHE))", &c, "baseline-view");
    cap_free(&c);
    // Child-only captures.
    HWND kids[4] = {g_sb, g_gl[0], g_gl[1], g_wvhost};
    for (int i = 0; i < 4; i++) {
        if (!kids[i]) continue;
        capture(kids[i], PW_RENDERFULLCONTENT, &c);
        child_report("PrintWindow(child,PW_RENDERFULLCONTENT)", kids[i], &c);
        cap_free(&c);
        capture_bitblt(kids[i], &c);
        child_report("BitBlt(GetDC(child))", kids[i], &c);
        cap_free(&c);
    }
    // GL presentation rate while off-screen.
    LONG f0 = g_glp[0].frames, f1 = g_glp[1].frames;
    double t0 = now_ms();
    pump_for(1000);
    double dt = now_ms() - t0;
    jlog("{\"t\":\"gl_rate\",\"tag\":\"%s\",\"gl1_fps\":%.1f,\"gl2_fps\":%.1f}", cfg.tag,
         (g_glp[0].frames - f0) * 1000.0 / dt, (g_glp[1].frames - f1) * 1000.0 / dt);
    // Does PrintWindow(PW_RENDERFULLCONTENT) force a pending WM_PAINT? Invalidate
    // with a new background color but do not pump, then look.
    g_alt_bg = 1;
    g_content_version++;
    if (g_sb) InvalidateRect(g_sb, NULL, FALSE);
    else InvalidateRect(g_top, &g_L.sb, FALSE);
    LONG p0 = C.sb_paint + C.top_paint;
    Cap cv, cp, c1, c2;
    capture_view(&cv);
    LONG p1 = C.sb_paint + C.top_paint;
    LONG frozen = 0;
    Cap c0p;
    capture(g_top, 0, &c0p);  // plain PrintWindow (no PW_RENDERFULLCONTENT)
    LONG p1a = C.sb_paint + C.top_paint;
    Hist h0p;
    hist(&c0p, g_L.sb, &h0p);
    jlog("{\"t\":\"repaint_probe_pw0\",\"tag\":\"%s\",\"pw0_before_pump\":{\"sb\":%d,\"sb2\":%d,\"paints\":%ld}}", cfg.tag,
         h0p.n[K_SB], h0p.n[K_SB2], p1a - p1);
    cap_free(&c0p);
    p1 = p1a;
    capture_passive(&cp, &frozen);
    LONG p1b = C.sb_paint + C.top_paint;
    capture(g_top, PW_RENDERFULLCONTENT, &c1);
    LONG p2 = C.sb_paint + C.top_paint;
    Hist hv, hp, h1, h2;
    hist(&cv, g_L.sb, &hv);
    hist(&cp, g_L.sb, &hp);
    hist(&c1, g_L.sb, &h1);
    pump_idle(300);
    capture(g_top, PW_RENDERFULLCONTENT, &c2);
    hist(&c2, g_L.sb, &h2);
    jlog("{\"t\":\"repaint_probe\",\"tag\":\"%s\",\"bitblt_view_before_pump\":{\"sb\":%d,\"sb2\":%d,\"paints\":%ld},"
         "\"passive_prf_before_pump\":{\"sb\":%d,\"sb2\":%d,\"paints\":%ld,\"deferred\":%ld},"
         "\"prf_before_pump\":{\"sb\":%d,\"sb2\":%d,\"paints_during_prf\":%ld},\"prf_after_pump\":{\"sb\":%d,"
         "\"sb2\":%d}}",
         cfg.tag, hv.n[K_SB], hv.n[K_SB2], p1 - p0, hp.n[K_SB], hp.n[K_SB2], p1b - p1, frozen, h1.n[K_SB],
         h1.n[K_SB2], p2 - p1b, h2.n[K_SB], h2.n[K_SB2]);
    cap_free(&cv);
    cap_free(&cp);
    cap_free(&c1);
    cap_free(&c2);
    g_alt_bg = 0;
    g_content_version++;
    if (g_sb) InvalidateRect(g_sb, NULL, FALSE);
    else InvalidateRect(g_top, &g_L.sb, FALSE);
    settle();
}
// Expected 3-px sidebar marker band: pixels in the band that are not marker
// ("missing") and marker pixels anywhere else ("stale" = old content shown).
static void marker_check(const Cap *c, int *missing, int *stale) {
    int x0 = g_L.sb.right - 3, x1 = g_L.sb.right;
    *missing = 0;
    *stale = 0;
    if (!c->px) return;
    for (int y = 0; y < c->h; y++)
        for (int x = 0; x < c->w; x++) {
            int k = classify(c->px[y * c->w + x]);
            int in = x >= x0 && x < x1 && y >= g_L.sb.top && y < g_L.sb.bottom;
            if (in && k != K_SBMARK) (*missing)++;
            else if (!in && k == K_SBMARK) (*stale)++;
        }
}

typedef struct { int steps_bad; long px_bad; int worst; } Acc;
static void acc_add(Acc *a, int bad) {
    if (bad <= 0) return;
    a->steps_bad++;
    a->px_bad += bad;
    if (bad > a->worst) a->worst = bad;
}
static int acc_json(char *b, size_t cap, const char *name, const Acc *a) {
    return snprintf(b, cap, "\"%s\":{\"bad_steps\":%d,\"bad_px\":%ld,\"worst\":%d}", name, a->steps_bad, a->px_bad,
                    a->worst);
}

typedef struct {
    int steps;
    // I = passive PrintWindow right after the layout (what DWM has now; our
    //     pending WM_PAINTs are deferred, not serviced)
    // S = after pumping to idle (normal PrintWindow)
    Acc i_sb, i_tab, i_gl1, i_wv, i_mark_missing, i_mark_stale;  // 1st DWM frame after the layout
    Acc j_sb, j_tab, j_gl1, j_wv, j_mark_missing, j_mark_stale;  // 2nd DWM frame (still no pumping)
    Acc s_sb, s_tab, s_gl1, s_wv, s_mark_missing, s_mark_stale;
    double t_layout_sum, t_layout_max, t_settle_sum, t_settle_max;
    LONG frozen_paints;
    LONG sb_size, sb_paint, sb_frames, top_paint, top_size;
} Storm;

static int cmp_d(const void *a, const void *b) {
    double x = *(const double *)a, y = *(const double *)b;
    return x < y ? -1 : x > y;
}
static void pct(double *v, int n, double *p50, double *p95, double *mx) {
    *p50 = *p95 = *mx = 0;
    if (n <= 0) return;
    qsort(v, n, sizeof(double), cmp_d);
    *p50 = v[n / 2];
    *p95 = v[(n * 95) / 100 < n ? (n * 95) / 100 : n - 1];
    *mx = v[n - 1];
}

static void storm_json(const char *name, const Storm *s) {
    char cj[512], b[4096];
    cfg_json(cj, sizeof(cj));
    const Acc *acc[] = {&s->s_sb, &s->s_tab, &s->s_gl1, &s->s_wv, &s->s_mark_missing, &s->s_mark_stale};
    const char *nm[] = {"set_sidebar", "set_tab", "set_gl1", "set_wv", "set_marker_missing", "set_marker_stale"};
    int n = 0;
    for (int i = 0; i < 6; i++) {
        if (i) n += snprintf(b + n, sizeof(b) - n, ",");
        n += acc_json(b + n, sizeof(b) - n, nm[i], acc[i]);
    }
    double f50, f95, fmx, d50, d95, dmx, e50, e95, emx;
    pct(S_frame, S_n, &f50, &f95, &fmx);
    pct(S_draw, S_n, &d50, &d95, &dmx);
    pct(S_end, S_n, &e50, &e95, &emx);
    jlog("{\"t\":\"storm\",\"tag\":\"%s\",\"name\":\"%s\",\"cfg\":%s,\"steps\":%d,%s,"
         "\"t_layout_ms\":{\"mean\":%.3f,\"max\":%.3f},\"t_settle_ms\":{\"mean\":%.3f,\"max\":%.3f},"
         "\"sb_frame_ms\":{\"n\":%d,\"p50\":%.3f,\"p95\":%.3f,\"max\":%.3f},\"sb_draw_ms\":{\"p50\":%.3f,\"p95\":%.3f},"
         "\"sb_enddraw_ms\":{\"p50\":%.3f,\"p95\":%.3f,\"max\":%.3f},\"frozen_paints\":%ld,\"top_WM_SIZE\":%ld,"
         "\"sb_WM_SIZE\":%ld,\"sb_WM_PAINT\":%ld,\"sb_frames\":%ld,\"top_WM_PAINT\":%ld}",
         cfg.tag, name, cj, s->steps, b, s->t_layout_sum / s->steps, s->t_layout_max, s->t_settle_sum / s->steps,
         s->t_settle_max, S_n, f50, f95, fmx, d50, d95, e50, e95, emx, s->frozen_paints, s->top_size, s->sb_size,
         s->sb_paint, s->sb_frames, s->top_paint);
}

static void keep_worst(Cap *dst, int *worst, Cap *src, int bad) {
    if (bad > *worst) {
        *worst = bad;
        cap_free(dst);
        *dst = *src;
        memset(src, 0, sizeof(*src));
    }
}

// Analyze one capture for the storm: sidebar/tab/GL1/WebView2 + marker.
// (GL2 is excluded: in an off-screen top-level only the first-created GL
// child presents; see gl2 notes in the decision record.)
static int storm_eval(const Cap *c, Acc *sb, Acc *tab, Acc *gl1, Acc *wv, Acc *mm, Acc *ms) {
    Hist h;
    int miss, stale, total = 0;
    hist(c, g_L.sb, &h);
    int b = bad_sidebar(&h);
    acc_add(sb, b);
    total += b;
    hist(c, g_L.tab, &h);
    b = bad_tab(&h);
    acc_add(tab, b);
    total += b;
    hist(c, g_L.gl1, &h);
    b = bad_gl(&h);
    acc_add(gl1, b);
    total += b;
    if (cfg.webview) {
        hist(c, g_L.wv, &h);
        b = bad_wv(&h);
        acc_add(wv, b);
        total += b;
    }
    marker_check(c, &miss, &stale);
    acc_add(mm, miss);
    acc_add(ms, stale);
    return total + miss + stale;
}

// kind 0: top-level resize storm; kind 1: sidebar-width drag storm.
static void run_storm(int kind) {
    settle();
    Storm s;
    memset(&s, 0, sizeof(s));
    struct Counters c0 = C;
    S_n = 0;
    RECT wr0;
    GetWindowRect(g_top, &wr0);
    int W0 = wr0.right - wr0.left, H0 = wr0.bottom - wr0.top;
    UINT dpi = dpi_for(g_top);
    int base_sbw = MulDiv(g_sbw_dip, dpi, 96);
    g_in_storm = 1;
    Cap w_i = {0}, w_s = {0};
    int wv_i = 0, wv_s = 0;
    for (int i = 0; i < cfg.steps; i++) {
        double t0 = now_ms();
        if (kind == 0) {
            int w = W0 + (int)(260.0 * sin(i * 0.61)) + (i % 2 ? 37 : -23);
            int h = H0 + (int)(180.0 * cos(i * 0.47));
            SetWindowPos(g_top, NULL, 0, 0, w, h, SWP_NOMOVE | SWP_NOZORDER | SWP_NOACTIVATE | SWP_NOOWNERZORDER);
        } else {
            g_sbw_override_px = base_sbw + (int)(base_sbw * 0.45 * sin(i * 0.73)) + (i % 2 ? 9 : -7);
            // What a sidebar drag does in wmux: relayout + invalidate the chrome.
            SendMessageW(g_top, WM_SIZE, 0, 0);
        }
        double t1 = now_ms();
        if (cfg.nocap) {
            double t2n = now_ms();
            pump_idle(500);
            double t3n = now_ms();
            s.t_settle_sum += t3n - t2n;
            if (t3n - t2n > s.t_settle_max) s.t_settle_max = t3n - t2n;
            s.t_layout_sum += t1 - t0;
            if (t1 - t0 > s.t_layout_max) s.t_layout_max = t1 - t0;
            s.steps++;
            pump_for(16);
            continue;
        }
        // NOTE: a "first DWM frame after the layout" probe (DwmFlush + passive
        // PrintWindow with deferred WM_PAINTs) always shows the pre-step frame:
        // DWM keeps the old surface until pending paints are serviced, and an
        // off-screen window's redirection surface is not live-composed. So the
        // storm checks the settled state only; see the decision record.
        (void)w_i;
        (void)wv_i;
        double t2 = now_ms();
        pump_idle(500);
        double t3 = now_ms();
        wait_gl_frames(1, 50);
        pump_idle(100);
        Cap cs;
        capture(g_top, PW_RENDERFULLCONTENT, &cs);
        int bs = storm_eval(&cs, &s.s_sb, &s.s_tab, &s.s_gl1, &s.s_wv, &s.s_mark_missing, &s.s_mark_stale);
        keep_worst(&w_s, &wv_s, &cs, bs);
        cap_free(&cs);
        double tl = t1 - t0, tsettle = t3 - t2;
        s.t_layout_sum += tl;
        if (tl > s.t_layout_max) s.t_layout_max = tl;
        s.t_settle_sum += tsettle;
        if (tsettle > s.t_settle_max) s.t_settle_max = tsettle;
        s.steps++;
    }
    g_in_storm = 0;
    s.top_size = C.top_size - c0.top_size;
    s.sb_size = C.sb_size - c0.sb_size;
    s.sb_paint = C.sb_paint - c0.sb_paint;
    s.sb_frames = C.sb_frames - c0.sb_frames;
    s.top_paint = C.top_paint - c0.top_paint;
    const char *name = cfg.nocap ? (kind == 0 ? "resize_nocap" : "sidebar_drag_nocap") : (kind == 0 ? "resize" : "sidebar_drag");
    storm_json(name, &s);
    char nm[64];
    if (w_i.px) {
        snprintf(nm, sizeof(nm), "%s-worst-immediate", name);
        save_bmp(&w_i, nm);
    }
    if (w_s.px) {
        snprintf(nm, sizeof(nm), "%s-worst-settled", name);
        save_bmp(&w_s, nm);
    }
    cap_free(&w_i);
    cap_free(&w_s);
    // restore
    g_sbw_override_px = -1;
    SetWindowPos(g_top, NULL, 0, 0, W0, H0, SWP_NOMOVE | SWP_NOZORDER | SWP_NOACTIVATE | SWP_NOOWNERZORDER);
    SendMessageW(g_top, WM_SIZE, 0, 0);
    settle();
}
// ---------------------------------------------------------------------------
// Windows.Graphics.Capture recorder: every frame DWM composes for the window,
// without forcing paints. Each frame is checked for self-consistency.
// (WinRT ABI declared by slot; IIDs from the Windows SDK headers.)
// ---------------------------------------------------------------------------

DEFINE_GUID(S7_IID_IGraphicsCaptureItemInterop, 0x3628e81b, 0x3cac, 0x4c60, 0xb7, 0xf4, 0x23, 0xce, 0x0e, 0x0c, 0x33, 0x56);
DEFINE_GUID(S7_IID_IGraphicsCaptureItem, 0x79c3f95b, 0x31f7, 0x4ec2, 0xa4, 0x64, 0x63, 0x2e, 0xf5, 0xd3, 0x07, 0x60);
DEFINE_GUID(S7_IID_IFramePoolStatics2, 0x589b103f, 0x6bbc, 0x5df5, 0xa9, 0x91, 0x02, 0xe2, 0x8b, 0x3b, 0x66, 0xd5);
DEFINE_GUID(S7_IID_IGraphicsCaptureSession2, 0x2c39ae40, 0x7d2e, 0x5044, 0x80, 0x4e, 0x8b, 0x67, 0x99, 0xd4, 0xcf, 0x9e);
DEFINE_GUID(S7_IID_IGraphicsCaptureSession3, 0xf2cdd966, 0x22ae, 0x5ea1, 0x95, 0x96, 0x3a, 0x28, 0x93, 0x44, 0xc3, 0xbe);
DEFINE_GUID(S7_IID_IDirect3DDevice, 0xa37624ab, 0x8d5f, 0x4650, 0x9d, 0x3e, 0x9e, 0xae, 0x3d, 0x9b, 0xc6, 0x70);
DEFINE_GUID(S7_IID_IDirect3DDxgiInterfaceAccess, 0xa9b3d012, 0x3df2, 0x4ee3, 0xb8, 0xd1, 0x86, 0x95, 0xf4, 0x57, 0xd3, 0xc1);
DEFINE_GUID(S7_IID_IClosable, 0x30d5a829, 0x7fa4, 0x4026, 0x83, 0xbb, 0xd7, 0x5b, 0xae, 0x4e, 0xa9, 0x9e);

typedef struct HSTRING__ *S7HSTRING;
typedef struct { INT32 w, h; } SizeI32;
#define VT(o) (*(void ***)(o))

typedef struct {
    LONG frames, glitched, bad_rows, missing_rows, gap_rows, overlap_rows, gl_bad_rows;
    long bad_px;
    int worst;
    int ox, oy;           // client origin inside the captured frame
    HRESULT init_hr;
    int border_off_hr;
    LONG frame_w, frame_h;  // last frame content size
} WgcStats;

static volatile LONG g_wgc_run, g_wgc_ready;
static int g_wgc_verbose;
static HANDLE g_wgc_thread;
static WgcStats g_wgc;
static CRITICAL_SECTION g_wgc_cs;
static DWORD *g_wgc_worst_px;
static int g_wgc_worst_w, g_wgc_worst_h;

static int wgc_cls(DWORD p) { return classify(p & 0xFFFFFF); }

// Self-consistency of one composed frame (BGRA rows, client origin ox/oy).
static void wgc_analyze(const BYTE *base, UINT pitch, int fw, int fh, int ox, int oy) {
    int cw = fw - 2 * ox, ch = fh - oy - ox;
    if (cw <= 20 || ch <= 20) return;
    int bad = 0, badrows = 0, miss = 0, gap = 0, ovl = 0, glbad = 0;
    for (int y = 2; y < ch - 1; y += 6) {
        const DWORD *row = (const DWORD *)(base + (size_t)(y + oy) * pitch) + ox;
        int mag = -1, cyan = -1, rowbad = 0;
        int lim = cw < 1400 ? cw : 1400;
        for (int x = 0; x < lim; x++) {
            int k = wgc_cls(row[x]);
            if (k == K_SBMARK && mag < 0) mag = x;
            if (k == K_GLMARK && cyan < 0) cyan = x;
            if (mag < 0 && cyan < 0) {
                if (k == K_SENT || k == K_BLACK || k == K_PARENT || k == K_TAB || k == K_GLERASE || k == K_WVHOST ||
                    k == K_GL || k == K_WV)
                    rowbad++;
            }
            if (mag >= 0 && cyan >= 0) {
                // a few GL pixels after the marker
                for (int xx = cyan + 3; xx < cyan + 40 && xx < lim; xx++) {
                    int kk = wgc_cls(row[xx]);
                    if (kk != K_GL && kk != K_GLMARK) {
                        glbad++;
                        break;
                    }
                }
                break;
            }
        }
        if (y < 48) continue;  // top rows: tab bar region spans the content side
        if (mag < 0) miss++;
        else if (cyan >= 0 && cyan < mag) ovl++;
        else if (cyan >= 0 && cyan > mag + 3) gap++;
        if (rowbad > 2) {
            badrows++;
            bad += rowbad;
        }
    }
    int glitch = bad + miss * 10 + gap * 10 + ovl * 10 + glbad * 10;
    if (g_wgc_verbose) {
        // geometry of this frame: sidebar marker x (mid row), sidebar/GL bottoms, tab bar right end
        int mid = ch / 2, magx = -1, cyx = -1, sbbot = -1, glbot = -1, tabr = -1;
        const DWORD *row = (const DWORD *)(base + (size_t)(mid + oy) * pitch) + ox;
        for (int x = 0; x < cw; x++) {
            int k = wgc_cls(row[x]);
            if (k == K_SBMARK && magx < 0) magx = x;
            if (k == K_GLMARK && cyx < 0) cyx = x;
        }
        for (int y = 0; y < ch; y++) {
            const DWORD *r2 = (const DWORD *)(base + (size_t)(y + oy) * pitch) + ox;
            if (magx >= 0 && wgc_cls(r2[magx]) == K_SBMARK) sbbot = y;
            if (cyx >= 0 && wgc_cls(r2[cyx]) == K_GLMARK) glbot = y;
        }
        const DWORD *r3 = (const DWORD *)(base + (size_t)(10 + oy) * pitch) + ox;
        for (int x = 0; x < cw; x++)
            if (wgc_cls(r3[x]) == K_TAB) tabr = x;
        jlog("{\"t\":\"wgc_frame\",\"tag\":\"%s\",\"ms\":%.1f,\"frame\":[%d,%d],\"client\":[%d,%d],\"sb_marker_x\":%d,"
             "\"sb_bottom\":%d,\"gl_marker_x\":%d,\"gl_bottom\":%d,\"tab_right\":%d,\"glitch\":%d}",
             cfg.tag, now_ms(), fw, fh, cw, ch, magx, sbbot, cyx, glbot, tabr, glitch);
    }
    EnterCriticalSection(&g_wgc_cs);
    g_wgc.frames++;
    g_wgc.frame_w = fw;
    g_wgc.frame_h = fh;
    if (glitch > 0) g_wgc.glitched++;
    g_wgc.bad_rows += badrows;
    g_wgc.missing_rows += miss;
    g_wgc.gap_rows += gap;
    g_wgc.overlap_rows += ovl;
    g_wgc.gl_bad_rows += glbad;
    g_wgc.bad_px += bad;
    if (glitch > g_wgc.worst && (size_t)fw * fh < 8000000) {
        g_wgc.worst = glitch;
        free(g_wgc_worst_px);
        g_wgc_worst_px = (DWORD *)malloc((size_t)fw * fh * 4);
        if (g_wgc_worst_px) {
            for (int y = 0; y < fh; y++) memcpy(g_wgc_worst_px + (size_t)y * fw, base + (size_t)y * pitch, (size_t)fw * 4);
            g_wgc_worst_w = fw;
            g_wgc_worst_h = fh;
        }
    }
    LeaveCriticalSection(&g_wgc_cs);
}

typedef HRESULT(WINAPI *PFN_WindowsCreateString)(LPCWSTR, UINT32, S7HSTRING *);
typedef HRESULT(WINAPI *PFN_WindowsDeleteString)(S7HSTRING);
typedef HRESULT(WINAPI *PFN_RoGetActivationFactory)(S7HSTRING, REFIID, void **);
typedef HRESULT(WINAPI *PFN_CreateD3DDeviceFromDXGI)(IDXGIDevice *, void **);  // out: IInspectable*

static DWORD WINAPI wgc_thread(void *arg) {
    (void)arg;
    HRESULT hr = CoInitializeEx(NULL, COINIT_MULTITHREADED);
    HMODULE cb = LoadLibraryW(L"combase.dll"), d3 = LoadLibraryW(L"d3d11.dll");
    PFN_WindowsCreateString wcs = (PFN_WindowsCreateString)(void *)GetProcAddress(cb, "WindowsCreateString");
    PFN_WindowsDeleteString wds = (PFN_WindowsDeleteString)(void *)GetProcAddress(cb, "WindowsDeleteString");
    PFN_RoGetActivationFactory rgaf = (PFN_RoGetActivationFactory)(void *)GetProcAddress(cb, "RoGetActivationFactory");
    PFN_CreateD3DDeviceFromDXGI cdev =
        (PFN_CreateD3DDeviceFromDXGI)(void *)GetProcAddress(d3, "CreateDirect3D11DeviceFromDXGIDevice");
    ID3D11Device *dev = NULL;
    ID3D11DeviceContext *ctx = NULL;
    void *interop = NULL, *item = NULL, *statics = NULL, *pool = NULL, *session = NULL, *wdev = NULL;
    void *insp = NULL;  // IInspectable
    IDXGIDevice *dx = NULL;
    ID3D11Texture2D *staging = NULL;
    UINT sw = 0, sh = 0;
    S7HSTRING hs = NULL;
    if (!wcs || !rgaf || !cdev) hr = E_NOINTERFACE;
    if (SUCCEEDED(hr))
        hr = D3D11CreateDevice(NULL, D3D_DRIVER_TYPE_HARDWARE, NULL, D3D11_CREATE_DEVICE_BGRA_SUPPORT, NULL, 0,
                               D3D11_SDK_VERSION, &dev, NULL, &ctx);
    if (SUCCEEDED(hr)) hr = ID3D11Device_QueryInterface(dev, &IID_IDXGIDevice, (void **)&dx);
    if (SUCCEEDED(hr)) hr = cdev(dx, &insp);
    if (SUCCEEDED(hr)) hr = ((HRESULT(STDMETHODCALLTYPE *)(void *, REFIID, void **))VT(insp)[0])(insp, &S7_IID_IDirect3DDevice, &wdev);
    const wchar_t *c1 = L"Windows.Graphics.Capture.GraphicsCaptureItem";
    if (SUCCEEDED(hr)) hr = wcs(c1, (UINT32)wcslen(c1), &hs);
    if (SUCCEEDED(hr)) hr = rgaf(hs, &S7_IID_IGraphicsCaptureItemInterop, &interop);
    if (hs) wds(hs);
    hs = NULL;
    if (SUCCEEDED(hr))
        hr = ((HRESULT(STDMETHODCALLTYPE *)(void *, HWND, REFIID, void **))VT(interop)[3])(interop, g_top,
                                                                                          &S7_IID_IGraphicsCaptureItem, &item);
    SizeI32 isz = {0, 0};
    if (SUCCEEDED(hr)) hr = ((HRESULT(STDMETHODCALLTYPE *)(void *, SizeI32 *))VT(item)[7])(item, &isz);
    const wchar_t *c2 = L"Windows.Graphics.Capture.Direct3D11CaptureFramePool";
    if (SUCCEEDED(hr)) hr = wcs(c2, (UINT32)wcslen(c2), &hs);
    if (SUCCEEDED(hr)) hr = rgaf(hs, &S7_IID_IFramePoolStatics2, &statics);
    if (hs) wds(hs);
    if (SUCCEEDED(hr))
        hr = ((HRESULT(STDMETHODCALLTYPE *)(void *, void *, int, INT32, SizeI32, void **))VT(statics)[6])(
            statics, wdev, 87 /*B8G8R8A8UIntNormalized*/, 3, isz, &pool);
    if (SUCCEEDED(hr)) hr = ((HRESULT(STDMETHODCALLTYPE *)(void *, void *, void **))VT(pool)[10])(pool, item, &session);
    if (SUCCEEDED(hr)) {
        void *s2 = NULL, *s3 = NULL;
        if (SUCCEEDED(((HRESULT(STDMETHODCALLTYPE *)(void *, REFIID, void **))VT(session)[0])(session, &S7_IID_IGraphicsCaptureSession2, &s2))) {
            ((HRESULT(STDMETHODCALLTYPE *)(void *, BYTE))VT(s2)[7])(s2, 0);  // no cursor
            ((IUnknown *)s2)->lpVtbl->Release((IUnknown *)s2);
        }
        if (SUCCEEDED(((HRESULT(STDMETHODCALLTYPE *)(void *, REFIID, void **))VT(session)[0])(session, &S7_IID_IGraphicsCaptureSession3, &s3))) {
            g_wgc.border_off_hr = ((HRESULT(STDMETHODCALLTYPE *)(void *, BYTE))VT(s3)[7])(s3, 0);  // no yellow border
            ((IUnknown *)s3)->lpVtbl->Release((IUnknown *)s3);
        }
        hr = ((HRESULT(STDMETHODCALLTYPE *)(void *))VT(session)[6])(session);  // StartCapture
    }
    g_wgc.init_hr = hr;
    InterlockedExchange(&g_wgc_ready, 1);
    while (SUCCEEDED(hr) && g_wgc_run) {
        void *frame = NULL;
        HRESULT fh = ((HRESULT(STDMETHODCALLTYPE *)(void *, void **))VT(pool)[7])(pool, &frame);
        if (FAILED(fh) || !frame) {
            Sleep(1);
            continue;
        }
        SizeI32 fsz = {0, 0};
        void *surf = NULL, *acc = NULL;
        ID3D11Texture2D *tex = NULL;
        ((HRESULT(STDMETHODCALLTYPE *)(void *, SizeI32 *))VT(frame)[8])(frame, &fsz);
        if (SUCCEEDED(((HRESULT(STDMETHODCALLTYPE *)(void *, void **))VT(frame)[6])(frame, &surf)) &&
            SUCCEEDED(((HRESULT(STDMETHODCALLTYPE *)(void *, REFIID, void **))VT(surf)[0])(surf, &S7_IID_IDirect3DDxgiInterfaceAccess, &acc)) &&
            SUCCEEDED(((HRESULT(STDMETHODCALLTYPE *)(void *, REFIID, void **))VT(acc)[3])(acc, &IID_ID3D11Texture2D, (void **)&tex))) {
            D3D11_TEXTURE2D_DESC d;
            ID3D11Texture2D_GetDesc(tex, &d);
            if (!staging || sw != d.Width || sh != d.Height) {
                if (staging) ID3D11Texture2D_Release(staging);
                D3D11_TEXTURE2D_DESC sd = d;
                sd.Usage = D3D11_USAGE_STAGING;
                sd.BindFlags = 0;
                sd.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
                sd.MiscFlags = 0;
                staging = NULL;
                ID3D11Device_CreateTexture2D(dev, &sd, NULL, &staging);
                sw = d.Width;
                sh = d.Height;
            }
            if (staging) {
                ID3D11DeviceContext_CopyResource(ctx, (ID3D11Resource *)staging, (ID3D11Resource *)tex);
                D3D11_MAPPED_SUBRESOURCE m;
                if (SUCCEEDED(ID3D11DeviceContext_Map(ctx, (ID3D11Resource *)staging, 0, D3D11_MAP_READ, 0, &m))) {
                    int fw = fsz.w < (INT32)d.Width ? fsz.w : (int)d.Width;
                    int fhh = fsz.h < (INT32)d.Height ? fsz.h : (int)d.Height;
                    wgc_analyze((const BYTE *)m.pData, m.RowPitch, fw, fhh, g_wgc.ox, g_wgc.oy);
                    ID3D11DeviceContext_Unmap(ctx, (ID3D11Resource *)staging, 0);
                }
            }
            ID3D11Texture2D_Release(tex);
        }
        if (acc) ((IUnknown *)acc)->lpVtbl->Release((IUnknown *)acc);
        if (surf) ((IUnknown *)surf)->lpVtbl->Release((IUnknown *)surf);
        void *clo = NULL;
        if (SUCCEEDED(((HRESULT(STDMETHODCALLTYPE *)(void *, REFIID, void **))VT(frame)[0])(frame, &S7_IID_IClosable, &clo))) {
            ((HRESULT(STDMETHODCALLTYPE *)(void *))VT(clo)[6])(clo);
            ((IUnknown *)clo)->lpVtbl->Release((IUnknown *)clo);
        }
        ((IUnknown *)frame)->lpVtbl->Release((IUnknown *)frame);
        // The pool was created for the initial size; recreate when the window grows.
        if (fsz.w > isz.w || fsz.h > isz.h) {
            isz = fsz;
            ((HRESULT(STDMETHODCALLTYPE *)(void *, void *, int, SizeI32))VT(pool)[6])(pool, wdev, 87, isz);
        }
    }
    void *objs[] = {session, pool};
    for (int i = 0; i < 2; i++) {
        void *clo = NULL;
        if (objs[i] && SUCCEEDED(((HRESULT(STDMETHODCALLTYPE *)(void *, REFIID, void **))VT(objs[i])[0])(objs[i], &S7_IID_IClosable, &clo))) {
            ((HRESULT(STDMETHODCALLTYPE *)(void *))VT(clo)[6])(clo);
            ((IUnknown *)clo)->lpVtbl->Release((IUnknown *)clo);
        }
    }
    void *rel[] = {session, pool, statics, item, interop, wdev, insp};
    for (int i = 0; i < 7; i++)
        if (rel[i]) ((IUnknown *)rel[i])->lpVtbl->Release((IUnknown *)rel[i]);
    if (staging) ID3D11Texture2D_Release(staging);
    if (dx) IDXGIDevice_Release(dx);
    if (ctx) ID3D11DeviceContext_Release(ctx);
    if (dev) ID3D11Device_Release(dev);
    CoUninitialize();
    return 0;
}

static int wgc_start(void) {
    static int cs_init;
    if (!cs_init) {
        InitializeCriticalSection(&g_wgc_cs);
        cs_init = 1;
    }
    memset(&g_wgc, 0, sizeof(g_wgc));
    free(g_wgc_worst_px);
    g_wgc_worst_px = NULL;
    // client origin inside the captured frame (frame = extended frame bounds)
    RECT efb;
    POINT co = {0, 0};
    DwmGetWindowAttribute(g_top, DWMWA_EXTENDED_FRAME_BOUNDS, &efb, sizeof(efb));
    ClientToScreen(g_top, &co);
    g_wgc.ox = co.x - efb.left;
    g_wgc.oy = co.y - efb.top;
    g_wgc_run = 1;
    g_wgc_ready = 0;
    g_wgc_thread = CreateThread(NULL, 0, wgc_thread, NULL, 0, NULL);
    double end = now_ms() + 5000;
    while (!g_wgc_ready && now_ms() < end) pump_for(5);
    return SUCCEEDED(g_wgc.init_hr);
}

static void wgc_stop(void) {
    g_wgc_run = 0;
    if (g_wgc_thread) {
        WaitForSingleObject(g_wgc_thread, 5000);
        CloseHandle(g_wgc_thread);
        g_wgc_thread = NULL;
    }
}

static void wgc_reset(void) {
    EnterCriticalSection(&g_wgc_cs);
    int ox = g_wgc.ox, oy = g_wgc.oy;
    HRESULT ih = g_wgc.init_hr;
    int bh = g_wgc.border_off_hr;
    memset(&g_wgc, 0, sizeof(g_wgc));
    g_wgc.ox = ox;
    g_wgc.oy = oy;
    g_wgc.init_hr = ih;
    g_wgc.border_off_hr = bh;
    free(g_wgc_worst_px);
    g_wgc_worst_px = NULL;
    LeaveCriticalSection(&g_wgc_cs);
}

// Storm with normal pumping (like a real drag) while WGC records frames.
static void run_wgc_storm(int kind) {
    settle();
    if (!wgc_start()) {
        jlog("{\"t\":\"wgc\",\"tag\":\"%s\",\"error\":\"init\",\"hr\":\"0x%08lX\"}", cfg.tag, (unsigned long)g_wgc.init_hr);
        wgc_stop();
        return;
    }
    pump_for(300);
    wgc_reset();
    pump_for(300);  // idle baseline frames
    WgcStats idle = g_wgc;
    wgc_reset();
    RECT wr0;
    GetWindowRect(g_top, &wr0);
    int W0 = wr0.right - wr0.left, H0 = wr0.bottom - wr0.top;
    UINT dpi = dpi_for(g_top);
    int base_sbw = MulDiv(g_sbw_dip, dpi, 96);
    S_n = 0;
    struct Counters c0 = C;
    g_in_storm = 1;
    double tsum = 0, tmax = 0;
    for (int i = 0; i < cfg.steps; i++) {
        double t0 = now_ms();
        if (kind == 0) {
            int w = W0 + (int)(260.0 * sin(i * 0.61)) + (i % 2 ? 37 : -23);
            int h = H0 + (int)(180.0 * cos(i * 0.47));
            SetWindowPos(g_top, NULL, 0, 0, w, h, SWP_NOMOVE | SWP_NOZORDER | SWP_NOACTIVATE | SWP_NOOWNERZORDER);
        } else {
            g_sbw_override_px = base_sbw + (int)(base_sbw * 0.45 * sin(i * 0.73)) + (i % 2 ? 9 : -7);
            SendMessageW(g_top, WM_SIZE, 0, 0);
        }
        double t1 = now_ms() - t0;
        tsum += t1;
        if (t1 > tmax) tmax = t1;
        if (g_wgc_verbose) {
            RECT c;
            GetClientRect(g_top, &c);
            jlog("{\"t\":\"wgc_step\",\"tag\":\"%s\",\"ms\":%.1f,\"step\":%d,\"client\":[%ld,%ld],\"sb_w\":%ld,"
                 "\"gl1\":[%ld,%ld,%ld,%ld]}",
                 cfg.tag, now_ms(), i, c.right, c.bottom, g_L.sb.right, g_L.gl1.left, g_L.gl1.top, g_L.gl1.right,
                 g_L.gl1.bottom);
        }
        pump_idle(200);
        pump_for(8);
    }
    g_in_storm = 0;
    pump_for(400);  // trailing frames
    wgc_stop();
    WgcStats st = g_wgc;
    double f50, f95, fmx;
    pct(S_frame, S_n, &f50, &f95, &fmx);
    char cj[512];
    cfg_json(cj, sizeof(cj));
    const char *name = kind == 0 ? "wgc_resize" : "wgc_sidebar_drag";
    jlog("{\"t\":\"wgc_storm\",\"tag\":\"%s\",\"name\":\"%s\",\"cfg\":%s,\"steps\":%d,\"client_origin_in_frame\":[%d,%d],"
         "\"border_off_hr\":\"0x%08lX\",\"idle\":{\"frames\":%ld,\"glitched\":%ld},\"frames\":%ld,\"glitched_frames\":%ld,"
         "\"glitch_rows\":{\"bad\":%ld,\"sidebar_missing\":%ld,\"gap_between_sidebar_and_gl\":%ld,\"overlap\":%ld,"
         "\"gl_bad\":%ld},\"bad_px\":%ld,\"worst\":%d,\"t_layout_ms\":{\"mean\":%.2f,\"max\":%.2f},"
         "\"sb_frame_ms\":{\"n\":%d,\"p50\":%.2f,\"p95\":%.2f,\"max\":%.2f},\"sb_WM_PAINT\":%ld,\"sb_frames\":%ld,"
         "\"top_WM_PAINT\":%ld}",
         cfg.tag, name, cj, cfg.steps, st.ox, st.oy, (unsigned long)st.border_off_hr, idle.frames, idle.glitched,
         st.frames, st.glitched, st.bad_rows, st.missing_rows, st.gap_rows, st.overlap_rows, st.gl_bad_rows, st.bad_px,
         st.worst, tsum / cfg.steps, tmax, S_n, f50, f95, fmx, C.sb_paint - c0.sb_paint, C.sb_frames - c0.sb_frames,
         C.top_paint - c0.top_paint);
    if (g_wgc_worst_px) {
        Cap c;
        memset(&c, 0, sizeof(c));
        c.w = g_wgc_worst_w;
        c.h = g_wgc_worst_h;
        c.px = g_wgc_worst_px;
        char nm[64];
        snprintf(nm, sizeof(nm), "%s-worst-frame", name);
        save_bmp(&c, nm);
    }
    g_sbw_override_px = -1;
    SetWindowPos(g_top, NULL, 0, 0, W0, H0, SWP_NOMOVE | SWP_NOZORDER | SWP_NOACTIVATE | SWP_NOOWNERZORDER);
    SendMessageW(g_top, WM_SIZE, 0, 0);
    settle();
}
static void set_clip(HWND h, int on) {
    if (!h) return;
    LONG_PTR st = GetWindowLongPtrW(h, GWL_STYLE);
    st = on ? (st | WS_CLIPSIBLINGS) : (st & ~(LONG_PTR)WS_CLIPSIBLINGS);
    SetWindowLongPtrW(h, GWL_STYLE, st);
    SetWindowPos(h, NULL, 0, 0, 0, 0,
                 SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE | SWP_FRAMECHANGED | SWP_NOOWNERZORDER);
}

static void overlap_measure(const char *what, RECT ov, int zo, int clipcfg) {
    // Three samples 120 ms apart while the GL thread keeps presenting.
    int dom[3];
    char sj[3][1024];
    for (int k = 0; k < 3; k++) {
        if (k == 1 && g_sb) {  // a sidebar repaint between samples
            InvalidateRect(g_sb, NULL, FALSE);
            pump_idle(200);
        }
        pump_for(120);
        Cap c;
        capture(g_top, PW_RENDERFULLCONTENT, &c);
        Hist h;
        hist(&c, ov, &h);
        int sbpx = h.n[K_SB] + h.n[K_SBMARK] + h.n[K_OTHER] + h.n[K_RULER] + h.n[K_OVL];
        int glpx = h.n[K_GL] + h.n[K_GLMARK];
        int wvpx = h.n[K_WV] + h.n[K_WVMARK] + h.n[K_WVHOST];
        dom[k] = sbpx > glpx && sbpx > wvpx ? 1 : (glpx >= wvpx ? 2 : 3);
        hist_json(sj[k], sizeof(sj[k]), "h", &h);
        if (k == 0) {
            char nm[96];
            snprintf(nm, sizeof(nm), "overlap-%s-z%d-c%d", what, zo, clipcfg);
            save_bmp(&c, nm);
        }
        cap_free(&c);
    }
    static const char *dn[] = {"?", "d2d", "gl", "webview"};
    jlog("{\"t\":\"overlap\",\"tag\":\"%s\",\"what\":\"%s\",\"top_of_zorder\":\"%s\",\"gl_clipsib\":%d,"
         "\"d2d_clipsib\":%d,\"winner\":[\"%s\",\"%s\",\"%s\"],\"stable\":%s,\"samples\":[{%s},{%s},{%s}]}",
         cfg.tag, what, zo == 0 ? "d2d" : "other", clipcfg & 1, (clipcfg >> 1) & 1, dn[dom[0]], dn[dom[1]],
         dn[dom[2]], (dom[0] == dom[1] && dom[1] == dom[2]) ? "true" : "false", sj[0], sj[1], sj[2]);
}

static void test_overlap(void) {
    if (!g_sb) return;
    settle();
    UINT dpi = dpi_for(g_top);
    int ov = MulDiv(40, dpi, 96);
    for (int zo = 0; zo < 2; zo++) {
        for (int cc = 0; cc < 4; cc++) {
            set_clip(g_gl[0], cc & 1);
            set_clip(g_sb, (cc >> 1) & 1);
            g_overlap_px = ov;
            layout();
            SetWindowPos(zo == 0 ? g_sb : g_gl[0], HWND_TOP, 0, 0, 0, 0,
                         SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE | SWP_NOOWNERZORDER);
            RedrawWindow(g_top, NULL, NULL, RDW_INVALIDATE | RDW_ALLCHILDREN | RDW_UPDATENOW);
            pump_for(200);
            RECT o = {g_L.gl1.left, g_L.gl1.top, g_L.gl1.left + ov, g_L.gl1.bottom};
            overlap_measure("sidebar_over_gl1", o, zo, cc);
        }
    }
    g_overlap_px = 0;
    set_clip(g_gl[0], cfg.clip);
    set_clip(g_sb, cfg.clip);
    SetWindowPos(g_sb, HWND_TOP, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE | SWP_NOOWNERZORDER);
    layout();
    RedrawWindow(g_top, NULL, NULL, RDW_INVALIDATE | RDW_ALLCHILDREN | RDW_UPDATENOW);
    settle();
    // D2D overlay child above GL2 (and above the WebView2 host).
    int sz = MulDiv(60, dpi, 96);
    RECT gl1low = g_L.gl1;
    gl1low.top = (g_L.gl1.top + g_L.gl1.bottom) / 2;
    gl1low.left += MulDiv(80, dpi, 96);
    RECT targets[2] = {gl1low, g_L.wv};
    const char *names[2] = {"overlay_over_gl1", "overlay_over_webview"};
    for (int t = 0; t < (cfg.webview ? 2 : 1); t++) {
        RECT tr = targets[t];
        int x = tr.left + (tr.right - tr.left) / 2 - sz / 2, y = tr.top + (tr.bottom - tr.top) / 2 - sz / 2;
        for (int cc = 0; cc < 2; cc++) {
            HWND below = t == 0 ? g_gl[0] : g_wvhost;
            set_clip(below, cc);
            if (!g_ovl)
                g_ovl = CreateWindowExW(0, L"S7Overlay", L"", WS_CHILD | WS_VISIBLE | WS_CLIPSIBLINGS, x, y, sz, sz,
                                        g_top, NULL, g_inst, NULL);
            SetWindowPos(g_ovl, HWND_TOP, x, y, sz, sz, SWP_NOACTIVATE | SWP_NOOWNERZORDER | SWP_SHOWWINDOW);
            RedrawWindow(g_top, NULL, NULL, RDW_INVALIDATE | RDW_ALLCHILDREN | RDW_UPDATENOW);
            pump_for(300);
            RECT o = {x + 2, y + 2, x + sz - 2, y + sz - 2};
            overlap_measure(names[t], o, 0, cc);
            set_clip(below, cfg.clip);
        }
    }
    if (g_ovl) {
        DestroyWindow(g_ovl);
        g_ovl = NULL;
        if (o_br) ID2D1SolidColorBrush_Release(o_br);
        if (o_hrt) ID2D1HwndRenderTarget_Release(o_hrt);
        o_br = NULL;
        o_hrt = NULL;
    }
    RedrawWindow(g_top, NULL, NULL, RDW_INVALIDATE | RDW_ALLCHILDREN | RDW_UPDATENOW);
    settle();
}

static void dpi_snapshot(const char *phase) {
    settle();
    Cap c;
    capture(g_top, PW_RENDERFULLCONTENT, &c);
    Bad b = analyze(&c, NULL, 0);
    UINT dpi = dpi_for(g_top);
    FLOAT rx = 0, ry = 0;
    if (cfg.mode == MODE_HWNDRT && s_hrt) ID2D1RenderTarget_GetDpi((ID2D1RenderTarget *)s_hrt, &rx, &ry);
    else if (cfg.mode == MODE_FLIP && f_dc) ID2D1RenderTarget_GetDpi((ID2D1RenderTarget *)f_dc, &rx, &ry);
    else if (cfg.mode == MODE_DCRT && s_dcrt) ID2D1RenderTarget_GetDpi((ID2D1RenderTarget *)s_dcrt, &rx, &ry);
    RECT wr;
    GetWindowRect(g_top, &wr);
    jlog("{\"t\":\"dpi\",\"tag\":\"%s\",\"phase\":\"%s\",\"override\":%u,\"dpi_top\":%u,\"dpi_sidebar\":%u,"
         "\"dpi_gl1\":%u,\"rt_dpi\":%.1f,\"window\":[%ld,%ld,%ld,%ld],\"sidebar_w_px\":%ld,\"expected_sidebar_w_px\":%d,"
         "\"ruler_px\":%d,\"expected_ruler_px\":%.1f,\"title_ink_px\":%d,\"title_layout_dip\":%.2f,"
         "\"emoji_color_px\":%d,\"emoji_control_px\":%d,\"bad_total\":%d,\"bad_sb\":%d,"
         "\"WM_DPICHANGED\":%ld,\"WM_GETDPISCALEDSIZE\":%ld,\"sb_BEFOREPARENT\":%ld,\"sb_AFTERPARENT\":%ld,"
         "\"seq\":\"%s\"}",
         cfg.tag, phase, g_dpi_override, real_dpi(g_top), g_sb ? real_dpi(g_sb) : 0, real_dpi(g_gl[0]), rx, wr.left,
         wr.top, wr.right, wr.bottom, g_L.sb.right - g_L.sb.left, MulDiv(g_sbw_dip, dpi, 96), ruler_px(&c, dpi),
         100.0 * dpi / 96.0, title_ink_px(&c, 0, dpi), g_title_metrics_h, color_px(&c, 2, dpi), color_px(&c, 5, dpi),
         b.total, b.sb, C.top_dpichanged, C.top_getdpiscaled, C.sb_before, C.sb_after, g_seq);
    char nm[64];
    snprintf(nm, sizeof(nm), "dpi-%s", phase);
    save_bmp(&c, nm);
    cap_free(&c);
}

static void test_dpi(void) {
    dpi_snapshot("initial");
    // Real per-monitor DPI change, staying off-screen: move the window next
    // to (but outside) the monitor nearest to the target position.
    int tx = 1000, ty = 3500;
    char *env = getenv("S7_DPI_TARGET");
    if (env) sscanf(env, "%d,%d", &tx, &ty);
    g_seq[0] = 0;
    SetWindowPos(g_top, NULL, tx, ty, 0, 0, SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE | SWP_NOOWNERZORDER);
    pump_for(1500);
    {
        HMONITOR mon = MonitorFromWindow(g_top, MONITOR_DEFAULTTONEAREST);
        HMONITOR mnull = MonitorFromWindow(g_top, MONITOR_DEFAULTTONULL);
        MONITORINFOEXW mi;
        mi.cbSize = sizeof(mi);
        GetMonitorInfoW(mon, (MONITORINFO *)&mi);
        jlog("{\"t\":\"dpi_monitor\",\"tag\":\"%s\",\"nearest\":\"%ls\",\"defaulttonull\":%d,\"dpi_top\":%u}", cfg.tag,
             mi.szDevice, mnull != NULL, real_dpi(g_top));
    }
    dpi_snapshot("moved_near_other_monitor");
    // Same, but a sized move (some DPI logic only runs on size changes).
    g_seq[0] = 0;
    SetWindowPos(g_top, NULL, tx + 200, ty + 100, 1300, 850, SWP_NOZORDER | SWP_NOACTIVATE | SWP_NOOWNERZORDER);
    pump_for(1500);
    dpi_snapshot("sized_move_near_other_monitor");
    SetWindowPos(g_top, NULL, 0, 0, 1400, 900, SWP_NOMOVE | SWP_NOZORDER | SWP_NOACTIVATE | SWP_NOOWNERZORDER);
    g_seq[0] = 0;
    SetWindowPos(g_top, NULL, -32000, -32000, 0, 0, SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE | SWP_NOOWNERZORDER);
    pump_for(400);
    dpi_snapshot("moved_back");
    // Simulated scales 1.0 / 1.5 / 2.0 through the same code path the
    // WM_DPICHANGED handler uses (relayout + lazy SetDpi on the RT).
    UINT dpis[3] = {96, 144, 192};
    for (int i = 0; i < 3; i++) {
        g_dpi_override = dpis[i];
        g_seq[0] = 0;
        layout();
        RedrawWindow(g_top, NULL, NULL, RDW_INVALIDATE | RDW_ALLCHILDREN | RDW_UPDATENOW);
        char ph[32];
        snprintf(ph, sizeof(ph), "simulated_%u", dpis[i]);
        dpi_snapshot(ph);
    }
    g_dpi_override = 0;
    layout();
    RedrawWindow(g_top, NULL, NULL, RDW_INVALIDATE | RDW_ALLCHILDREN | RDW_UPDATENOW);
    settle();
    // What does a render target created with dpi = 0 report?
    if (g_sb && cfg.mode == MODE_HWNDRT) {
        hrt_discard();
        ID2D1HwndRenderTarget *t = NULL;
        HRESULT hr = hrt_create_for(g_sb, 0, 0, D2D1_PRESENT_OPTIONS_IMMEDIATELY, &t);
        FLOAT x = 0, y = 0;
        if (SUCCEEDED(hr)) {
            ID2D1RenderTarget_GetDpi((ID2D1RenderTarget *)t, &x, &y);
            ID2D1HwndRenderTarget_Release(t);
        }
        jlog("{\"t\":\"dpi_zero_rt\",\"tag\":\"%s\",\"hr\":\"0x%08lX\",\"reported_dpi\":%.1f,\"window_dpi\":%u}",
             cfg.tag, (unsigned long)hr, x, real_dpi(g_sb));
        InvalidateRect(g_sb, NULL, FALSE);  // recreate ours on the next paint
        settle();
    }
}

static void proc_stats(DWORD *handles, SIZE_T *priv, DWORD *gdi, DWORD *user) {
    GetProcessHandleCount(GetCurrentProcess(), handles);
    PROCESS_MEMORY_COUNTERS_EX pm;
    memset(&pm, 0, sizeof(pm));
    pm.cb = sizeof(pm);
    GetProcessMemoryInfo(GetCurrentProcess(), (PROCESS_MEMORY_COUNTERS *)&pm, sizeof(pm));
    *priv = pm.PrivateUsage;
    *gdi = GetGuiResources(GetCurrentProcess(), GR_GDIOBJECTS);
    *user = GetGuiResources(GetCurrentProcess(), GR_USEROBJECTS);
}

static void verify_sidebar(const char *phase) {
    settle();
    Cap c;
    capture(g_top, PW_RENDERFULLCONTENT, &c);
    Bad b = analyze(&c, NULL, 0);
    Hist h;
    hist(&c, g_L.sb, &h);
    jlog("{\"t\":\"devloss_verify\",\"tag\":\"%s\",\"phase\":\"%s\",\"bad_sb\":%d,\"bad_total\":%d,\"sb_px\":%d,"
         "\"text_px\":%d,\"recreates\":%ld,\"rt_created\":%u}",
         cfg.tag, phase, b.sb, b.total, h.n[K_SB], h.n[K_OTHER], C.sb_recreate, s_rt_created_count);
    cap_free(&c);
}

static void test_devloss(void) {
    settle();
    // 1) Injected D2DERR_RECREATE_TARGET at EndDraw -> full recovery path.
    LONG r0 = C.sb_recreate;
    double t0 = now_ms();
    g_inject = 1;
    if (g_sb) RedrawWindow(g_sb, NULL, NULL, RDW_INVALIDATE | RDW_UPDATENOW);
    else RedrawWindow(g_top, &g_L.sb, NULL, RDW_INVALIDATE | RDW_UPDATENOW);
    pump_idle(500);
    double t1 = now_ms();
    jlog("{\"t\":\"devloss_inject\",\"tag\":\"%s\",\"recreates\":%ld,\"recover_ms\":%.2f,\"last_hr\":\"0x%08lX\"}",
         cfg.tag, C.sb_recreate - r0, t1 - t0, (unsigned long)C.last_hr);
    verify_sidebar("after_injected_loss");
    // 2) Real recreation loop: drop and recreate every device resource 30x.
    DWORD h0, g0, u0, h1, g1, u1;
    SIZE_T p0, p1;
    proc_stats(&h0, &p0, &g0, &u0);
    double tmin = 1e9, tmax = 0, tsum = 0, csum = 0, cmax = 0, rsum = 0, rmax = 0;
    HRESULT lasthr = S_OK;
    int fails = 0;
    for (int i = 0; i < 30; i++) {
        double a = now_ms(), b;
        if (cfg.mode == MODE_HWNDRT) {
            hrt_discard();
            lasthr = hrt_create();
            b = now_ms();
            sb_render();
        } else if (cfg.mode == MODE_FLIP) {
            flip_discard();
            lasthr = flip_create();
            b = now_ms();
            sb_render();
        } else {
            dcrt_discard();
            lasthr = dcrt_create(dpi_for(g_top));
            b = now_ms();
            RedrawWindow(g_top, &g_L.sb, NULL, RDW_INVALIDATE | RDW_UPDATENOW);
        }
        if (FAILED(lasthr)) fails++;
        double e = now_ms();
        double d = e - a, cr = b - a, rr = e - b;
        tsum += d;
        csum += cr;
        rsum += rr;
        if (d < tmin) tmin = d;
        if (d > tmax) tmax = d;
        if (cr > cmax) cmax = cr;
        if (rr > rmax) rmax = rr;
    }
    pump_idle(300);
    proc_stats(&h1, &p1, &g1, &u1);
    jlog("{\"t\":\"devloss_recreate_loop\",\"tag\":\"%s\",\"iterations\":30,\"fails\":%d,\"last_hr\":\"0x%08lX\","
         "\"flip_create_hr\":\"0x%08lX\",\"ms\":{\"min\":%.2f,\"mean\":%.2f,\"max\":%.2f},"
         "\"create_ms\":{\"mean\":%.2f,\"max\":%.2f},\"first_frame_ms\":{\"mean\":%.2f,\"max\":%.2f},"
         "\"handles\":[%lu,%lu],\"private_kb\":[%llu,%llu],\"gdi\":[%lu,%lu],\"user\":[%lu,%lu]}",
         cfg.tag, fails, (unsigned long)lasthr, (unsigned long)f_last_create_hr, tmin, tsum / 30, tmax, csum / 30,
         cmax, rsum / 30, rmax, h0, h1,
         (unsigned long long)(p0 / 1024), (unsigned long long)(p1 / 1024), g0, g1, u0, u1);
    verify_sidebar("after_recreate_loop");
    // 3) Window state reported by the HWND RT for this off-screen window.
    if (cfg.mode == MODE_HWNDRT && s_hrt) {
        D2D1_WINDOW_STATE ws = ID2D1HwndRenderTarget_CheckWindowState(s_hrt);
        jlog("{\"t\":\"window_state\",\"tag\":\"%s\",\"state\":%d}", cfg.tag, (int)ws);
    }
}

static void test_dcrtdbg(void) {
    settle();
    g_paint_debug = 1;
    RECT r = g_L.sb, ur = {0};
    LONG tp0 = C.top_paint, df0 = C.dc_frames;
    InvalidateRect(g_top, &r, FALSE);
    BOOL has = GetUpdateRect(g_top, &ur, FALSE);
    UpdateWindow(g_top);
    LONG tp1 = C.top_paint, df1 = C.dc_frames;
    RedrawWindow(g_top, &r, NULL, RDW_INVALIDATE | RDW_UPDATENOW);
    LONG tp2 = C.top_paint, df2 = C.dc_frames;
    RedrawWindow(g_top, &r, NULL, RDW_INVALIDATE | RDW_UPDATENOW | RDW_ALLCHILDREN);
    LONG tp3 = C.top_paint, df3 = C.dc_frames;
    if (g_sb) RedrawWindow(g_sb, NULL, NULL, RDW_INVALIDATE | RDW_UPDATENOW);
    {
        Cap c;
        capture(g_top, PW_RENDERFULLCONTENT, &c);  // paints driven by PrintWindow, for comparison
        cap_free(&c);
    }
    jlog("{\"t\":\"dcrtdbg\",\"tag\":\"%s\",\"sb\":[%ld,%ld,%ld,%ld],\"has_update\":%d,\"update\":[%ld,%ld,%ld,%ld],"
         "\"InvalidateRect+UpdateWindow\":{\"top_paint\":%ld,\"dc_frames\":%ld},\"RedrawWindow\":{\"top_paint\":%ld,"
         "\"dc_frames\":%ld},\"RedrawWindow_allchildren\":{\"top_paint\":%ld,\"dc_frames\":%ld},\"in_send\":%d}",
         cfg.tag, r.left, r.top, r.right, r.bottom, has, ur.left, ur.top, ur.right, ur.bottom, tp1 - tp0, df1 - df0,
         tp2 - tp1, df2 - df1, tp3 - tp2, df3 - df2, InSendMessage());
    g_paint_debug = 0;
}
static void test_timing(void) {
    settle();
    const int N = 120;
    double *v = (double *)calloc(N, sizeof(double));
    double *wall = (double *)calloc(N, sizeof(double));
    double *dr = (double *)calloc(N, sizeof(double));
    double *ed = (double *)calloc(N, sizeof(double));
    for (int i = 0; i < N; i++) {
        double a = now_ms();
        if (g_sb) RedrawWindow(g_sb, NULL, NULL, RDW_INVALIDATE | RDW_UPDATENOW);
        else RedrawWindow(g_top, &g_L.sb, NULL, RDW_INVALIDATE | RDW_UPDATENOW);
        wall[i] = now_ms() - a;
        v[i] = C.sb_last_ms;
        dr[i] = C.last_draw_ms;
        ed[i] = C.last_enddraw_ms;
        pump_once();
    }
    // sort for percentiles
    for (int pass = 0; pass < 4; pass++) {
        double *x = pass == 0 ? v : pass == 1 ? wall : pass == 2 ? dr : ed;
        for (int i = 1; i < N; i++) {
            double k = x[i];
            int j = i - 1;
            while (j >= 0 && x[j] > k) {
                x[j + 1] = x[j];
                j--;
            }
            x[j + 1] = k;
        }
    }
    char cj[512];
    cfg_json(cj, sizeof(cj));
    jlog("{\"t\":\"timing\",\"tag\":\"%s\",\"cfg\":%s,\"frames\":%d,\"dpi\":%u,\"sidebar_px\":[%ld,%ld],"
         "\"frame_ms\":{\"p50\":%.3f,\"p95\":%.3f,\"max\":%.3f},\"wall_ms\":{\"p50\":%.3f,\"p95\":%.3f,\"max\":%.3f},"
         "\"draw_calls_ms\":{\"p50\":%.3f,\"p95\":%.3f},\"enddraw_ms\":{\"p50\":%.3f,\"p95\":%.3f,\"max\":%.3f}}",
         cfg.tag, cj, N, dpi_for(g_top), g_L.sb.right - g_L.sb.left, g_L.sb.bottom - g_L.sb.top, v[N / 2],
         v[(N * 95) / 100], v[N - 1], wall[N / 2], wall[(N * 95) / 100], wall[N - 1], dr[N / 2], dr[(N * 95) / 100],
         ed[N / 2], ed[(N * 95) / 100], ed[N - 1]);
    free(v);
    free(wall);
    free(dr);
    free(ed);
}

static void test_idle(void) {
    settle();
    struct Counters c0 = C;
    LONG f0 = g_glp[0].frames, f1 = g_glp[1].frames;
    pump_for(1500);
    jlog("{\"t\":\"idle_isolation\",\"tag\":\"%s\",\"ms\":1500,\"gl1_frames\":%ld,\"gl2_frames\":%ld,"
         "\"sb_WM_PAINT\":%ld,\"top_WM_PAINT\":%ld,\"sb_frames\":%ld}",
         cfg.tag, g_glp[0].frames - f0, g_glp[1].frames - f1, C.sb_paint - c0.sb_paint, C.top_paint - c0.top_paint,
         C.sb_frames - c0.sb_frames);
    // Parent invalidates its tab bar: does the child get dragged along?
    c0 = C;
    for (int i = 0; i < 20; i++) {
        InvalidateRect(g_top, &g_L.tab, FALSE);
        UpdateWindow(g_top);
    }
    pump_idle(200);
    jlog("{\"t\":\"invalidate_isolation\",\"tag\":\"%s\",\"parent_tabbar_invalidations\":20,\"top_WM_PAINT\":%ld,"
         "\"sb_WM_PAINT\":%ld,\"sb_frames\":%ld}",
         cfg.tag, C.top_paint - c0.top_paint, C.sb_paint - c0.sb_paint, C.sb_frames - c0.sb_frames);
}

// x64 ABI check for struct-returning COM methods (ID2D1RenderTarget::GetSize).
static void test_abi(int broken) {
    ID2D1RenderTarget *rt = NULL;
    if (cfg.mode == MODE_HWNDRT) {
        if (!s_hrt) hrt_create();
        rt = (ID2D1RenderTarget *)s_hrt;
    } else if (cfg.mode == MODE_FLIP) rt = (ID2D1RenderTarget *)f_dc;
    else return;
    if (!rt) return;
    void **vt = *(void ***)rt;
    // ID2D1RenderTarget vtable: IUnknown(3) + GetFactory(1) + 49 methods; GetSize is slot 53.
    typedef D2D1_SIZE_F *(STDMETHODCALLTYPE * GetSizeHidden)(ID2D1RenderTarget *, D2D1_SIZE_F *);
    typedef D2D1_SIZE_F(STDMETHODCALLTYPE * GetSizeByVal)(ID2D1RenderTarget *);
    GetSizeHidden hidden = (GetSizeHidden)vt[53];
    int same_as_mingw = (void *)hidden == (void *)rt->lpVtbl->GetSize;
    D2D1_SIZE_F out = {-1, -1};
    D2D1_SIZE_F *ret = hidden(rt, &out);
    RECT rc;
    GetClientRect(g_sb, &rc);
    jlog("{\"t\":\"abi\",\"tag\":\"%s\",\"slot53_is_GetSize\":%d,\"hidden_ptr_call\":{\"w\":%.2f,\"h\":%.2f,"
         "\"returned_ptr_ok\":%d},\"client_px\":[%ld,%ld],\"dpi\":%u}",
         cfg.tag, same_as_mingw, out.width, out.height, ret == &out, rc.right, rc.bottom, s_rt_dpi);
    if (broken) {
        // What naive C/Zig bindings do: declare the struct as the return value.
        GetSizeByVal byval = (GetSizeByVal)vt[53];
        D2D1_SIZE_F v = byval(rt);
        jlog("{\"t\":\"abi_broken\",\"tag\":\"%s\",\"byval_call\":{\"w\":%g,\"h\":%g}}", cfg.tag, v.width, v.height);
    }
}

static LONG WINAPI veh(PEXCEPTION_POINTERS e) {
    if (e->ExceptionRecord->ExceptionCode == EXCEPTION_ACCESS_VIOLATION) {
        jlog("{\"t\":\"abi_broken\",\"tag\":\"%s\",\"crash\":\"EXCEPTION_ACCESS_VIOLATION\"}", cfg.tag);
        ExitProcess(3);
    }
    return EXCEPTION_CONTINUE_SEARCH;
}

static void test_layered_info(void) {
    BYTE alpha = 0;
    DWORD flags = 0;
    COLORREF key = 0;
    BOOL ok = GetLayeredWindowAttributes(g_top, &key, &alpha, &flags);
    jlog("{\"t\":\"layered\",\"tag\":\"%s\",\"exstyle\":\"0x%08lX\",\"ok\":%d,\"alpha\":%u,\"flags\":%lu}", cfg.tag,
         (unsigned long)GetWindowLongW(g_top, GWL_EXSTYLE), ok, alpha, flags);
}

void run_tests(void) {
    // Wait for GL frames and (optionally) WebView2 to render its page.
    wait_gl_frames(5, 3000);
    if (cfg.webview) {
        double end = now_ms() + 20000;
        while (g_wv_state >= 0 && g_wv_state < 3 && now_ms() < end) pump_for(20);
        // First frame of the page: the region center stops being host/white,
        // stays stable for two captures; calibrate page + marker colors.
        int wv_ok = 0;
        double t_first = -1;
        double end2 = now_ms() + 10000;
        DWORD prev = 0;
        RGB3 authored = COL_WV, authored_mark = COL_WVMARK;
        while (now_ms() < end2) {
            pump_for(50);
            Cap c;
            capture(g_top, PW_RENDERFULLCONTENT, &c);
            if (c.px && !IsRectEmpty(&g_L.wv)) {
                int cx = (g_L.wv.left + g_L.wv.right) / 2, cy = g_L.wv.bottom - 20;
                DWORD p = c.px[cy * c.w + cx] & 0xFFFFFF;
                int k = classify(p);
                if (k != K_WVHOST && k != K_WHITE && k != K_SENT && k != K_BLACK && p == prev) {
                    COL_WV.r = (p >> 16) & 0xFF;
                    COL_WV.g = (p >> 8) & 0xFF;
                    COL_WV.b = p & 0xFF;
                    DWORD m = c.px[cy * c.w + g_L.wv.left + 1] & 0xFFFFFF;
                    COL_WVMARK.r = (m >> 16) & 0xFF;
                    COL_WVMARK.g = (m >> 8) & 0xFF;
                    COL_WVMARK.b = m & 0xFF;
                    wv_ok = 1;
                    t_first = now_ms() - g_wv_t0;
                    cap_free(&c);
                    break;
                }
                prev = p;
            }
            cap_free(&c);
        }
        jlog("{\"t\":\"wv2_color\",\"tag\":\"%s\",\"authored_bg\":[%u,%u,%u],\"rendered_bg\":[%u,%u,%u],"
             "\"authored_marker\":[%u,%u,%u],\"rendered_marker\":[%u,%u,%u]}",
             cfg.tag, authored.r, authored.g, authored.b, COL_WV.r, COL_WV.g, COL_WV.b, authored_mark.r,
             authored_mark.g, authored_mark.b, COL_WVMARK.r, COL_WVMARK.g, COL_WVMARK.b);
        char kids[2048];
        int n = snprintf(kids, sizeof(kids), "[");
        HWND k = g_wvhost ? GetWindow(g_wvhost, GW_CHILD) : NULL;
        int first = 1;
        while (k) {
            wchar_t cls[64];
            GetClassNameW(k, cls, 64);
            DWORD pid = 0;
            GetWindowThreadProcessId(k, &pid);
            n += snprintf(kids + n, sizeof(kids) - n, "%s{\"class\":\"%ls\",\"cross_process\":%d,\"style\":\"0x%08lX\"}",
                          first ? "" : ",", cls, pid != GetCurrentProcessId(),
                          (unsigned long)GetWindowLongW(k, GWL_STYLE));
            first = 0;
            k = GetWindow(k, GW_HWNDNEXT);
        }
        snprintf(kids + n, sizeof(kids) - n, "]");
        jlog("{\"t\":\"wv2_ready\",\"tag\":\"%s\",\"state\":%d,\"nav_ms\":%.0f,\"page_visible_in_capture\":%d,"
             "\"first_page_frame_ms\":%.0f,\"host_children\":%s}",
             cfg.tag, g_wv_state, g_wv_t_nav, wv_ok, t_first, kids);
    }
    if (cfg.layered) test_layered_info();
    if (want("abi")) test_abi(0);
    if (want("abi_broken")) {
        AddVectoredExceptionHandler(1, veh);
        test_abi(1);
    }
    if (want("capture")) test_capture();
    if (want("idle")) test_idle();
    if (want("resize")) run_storm(0);
    if (want("drag")) run_storm(1);
    if (want("wresize")) run_wgc_storm(0);
    if (want("wdrag")) run_wgc_storm(1);
    if (want("overlap")) test_overlap();
    if (want("dpi")) test_dpi();
    if (want("devloss")) test_devloss();
    if (want("dcrtdbg")) test_dcrtdbg();
    if (want("timing")) test_timing();
    jlog("{\"t\":\"done\",\"tag\":\"%s\",\"sb_frames\":%ld,\"sb_recreate\":%ld,\"gl_frames\":[%ld,%ld]}", cfg.tag,
         C.sb_frames, C.sb_recreate, g_glp[0].frames, g_glp[1].frames);
    PostMessageW(g_top, WM_CLOSE, 0, 0);
}

// ---------------------------------------------------------------------------
// main
// ---------------------------------------------------------------------------

static void parse_args(int argc, char **argv) {
    for (int i = 1; i < argc; i++) {
        char *a = argv[i];
        if (strncmp(a, "--", 2) != 0) continue;
        char *eq = strchr(a, '=');
        if (!eq) continue;
        *eq = 0;
        const char *k = a + 2, *v = eq + 1;
        int iv = atoi(v);
        if (!strcmp(k, "mode")) cfg.mode = !strcmp(v, "flip") ? MODE_FLIP : !strcmp(v, "dcrt") ? MODE_DCRT : MODE_HWNDRT;
        else if (!strcmp(k, "present")) cfg.present = iv;
        else if (!strcmp(k, "sync")) cfg.sync_paint = iv;
        else if (!strcmp(k, "defer")) cfg.defer = iv;
        else if (!strcmp(k, "webview")) cfg.webview = iv;
        else if (!strcmp(k, "clip")) cfg.clip = iv;
        else if (!strcmp(k, "layered")) cfg.layered = iv;
        else if (!strcmp(k, "swdcrt")) cfg.sw_dcrt = iv;
        else if (!strcmp(k, "swhwndrt")) cfg.sw_hwndrt = iv;
        else if (!strcmp(k, "flipnone")) cfg.flip_none = iv;
        else if (!strcmp(k, "flipvsync")) cfg.flip_vsync = iv;
        else if (!strcmp(k, "glwait")) cfg.gl_wait = iv;
        else if (!strcmp(k, "occloff")) cfg.occl_off = iv;
        else if (!strcmp(k, "nocopy")) cfg.nocopy = iv;
        else if (!strcmp(k, "steps")) cfg.steps = iv;
        else if (!strcmp(k, "pos")) sscanf(v, "%d,%d", &cfg.posx, &cfg.posy);
        else if (!strcmp(k, "glswap")) cfg.glswap = iv;
        else if (!strcmp(k, "nogl2")) cfg.nogl2 = iv;
        else if (!strcmp(k, "sblast")) cfg.sblast = iv;
        else if (!strcmp(k, "skipclean")) cfg.skipclean = iv;
        else if (!strcmp(k, "nocap")) cfg.nocap = iv;
        else if (!strcmp(k, "wgcverbose")) g_wgc_verbose = iv;
        else if (!strcmp(k, "tests")) snprintf(cfg.tests, sizeof(cfg.tests), "%s", v);
        else if (!strcmp(k, "out")) snprintf(cfg.out, sizeof(cfg.out), "%s", v);
        else if (!strcmp(k, "tag")) snprintf(cfg.tag, sizeof(cfg.tag), "%s", v);
    }
}

static ATOM reg(const wchar_t *name, WNDPROC proc, UINT style, HBRUSH bg) {
    WNDCLASSEXW wc;
    memset(&wc, 0, sizeof(wc));
    wc.cbSize = sizeof(wc);
    wc.style = style;
    wc.lpfnWndProc = proc;
    wc.hInstance = g_inst;
    wc.hCursor = LoadCursorW(NULL, (LPCWSTR)IDC_ARROW);
    wc.hbrBackground = bg;
    wc.lpszClassName = name;
    return RegisterClassExW(&wc);
}

static HBRUSH brush(RGB3 c) { return CreateSolidBrush(RGB(c.r, c.g, c.b)); }

int main(int argc, char **argv) {
    LARGE_INTEGER f;
    QueryPerformanceFrequency(&f);
    g_qpf = (double)f.QuadPart;
    parse_args(argc, argv);
    char path[MAX_PATH];
    snprintf(path, sizeof(path), "%s\\results.jsonl", cfg.out);
    g_out = fopen(path, "ab");
    g_inst = GetModuleHandleW(NULL);

    HMODULE u32 = GetModuleHandleW(L"user32.dll");
    PFN_SetProcessDpiAwarenessContext sp =
        (PFN_SetProcessDpiAwarenessContext)(void *)GetProcAddress(u32, "SetProcessDpiAwarenessContext");
    pGetDpiForWindow = (PFN_GetDpiForWindow)(void *)GetProcAddress(u32, "GetDpiForWindow");
    BOOL pm = sp ? sp((HANDLE)(INT_PTR)-4) : FALSE;  // PER_MONITOR_AWARE_V2 (wmux manifest)
    HRESULT hrc = CoInitializeEx(NULL, COINIT_APARTMENTTHREADED);
    CreateThread(NULL, 0, fg_watch, NULL, 0, NULL);

    HRESULT hr = D2D1CreateFactory(D2D1_FACTORY_TYPE_SINGLE_THREADED, &IID_ID2D1Factory1, NULL, (void **)&g_d2f);
    if (FAILED(hr)) {
        jlog("{\"t\":\"fatal\",\"what\":\"D2D1CreateFactory\",\"hr\":\"0x%08lX\"}", (unsigned long)hr);
        return 2;
    }
    hr = DWriteCreateFactory(DWRITE_FACTORY_TYPE_SHARED, &IID_IDWriteFactory, (IUnknown **)&g_dwf);
    if (FAILED(hr)) return 2;
    IDWriteFactory_CreateTextFormat(g_dwf, L"Segoe UI", NULL, DWRITE_FONT_WEIGHT_SEMI_BOLD, DWRITE_FONT_STYLE_NORMAL,
                                    DWRITE_FONT_STRETCH_NORMAL, 13.f, L"en-us", &g_tf_title);
    IDWriteFactory_CreateTextFormat(g_dwf, L"Segoe UI", NULL, DWRITE_FONT_WEIGHT_NORMAL, DWRITE_FONT_STYLE_NORMAL,
                                    DWRITE_FONT_STRETCH_NORMAL, 11.5f, L"en-us", &g_tf_sub);
    IDWriteTextFormat_SetWordWrapping(g_tf_title, DWRITE_WORD_WRAPPING_NO_WRAP);
    IDWriteTextFormat_SetWordWrapping(g_tf_sub, DWRITE_WORD_WRAPPING_NO_WRAP);

    g_br_gl = brush(COL_GLERASE);
    g_br_parent = brush(COL_PARENT);
    g_br_tab = brush(COL_TAB);
    g_br_div = brush(COL_DIV);
    g_br_wvhost = brush(COL_WVHOST);
    reg(L"S7Top", top_proc, CS_DBLCLKS, g_br_parent);  // wmux: CS_DBLCLKS + bg brush
    reg(L"S7Sidebar", sb_proc, 0, NULL);               // no class brush, no CS_*REDRAW
    reg(L"S7GL", gl_proc, CS_OWNDC, NULL);             // wmux WmuxTerminal: CS_OWNDC
    reg(L"S7WebHost", wvhost_proc, 0, NULL);
    reg(L"S7Overlay", ovl_proc, 0, NULL);

    DWORD ex = WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW | (cfg.layered ? WS_EX_LAYERED : 0);
    g_top = CreateWindowExW(ex, L"S7Top", L"S7 spike", WS_OVERLAPPEDWINDOW | WS_CLIPCHILDREN, cfg.posx, cfg.posy,
                            1400, 900, NULL, NULL, g_inst, NULL);
    if (!g_top) {
        jlog("{\"t\":\"fatal\",\"what\":\"CreateWindowExW(top)\",\"gle\":%lu}", GetLastError());
        return 2;
    }
    if (cfg.layered) SetLayeredWindowAttributes(g_top, 0, 230, LWA_ALPHA);
    RECT c;
    GetClientRect(g_top, &c);
    compute_layout(c.right, c.bottom, &g_L);
    DWORD cs = WS_CHILD | WS_VISIBLE | (cfg.clip ? WS_CLIPSIBLINGS : 0);
    if (cfg.mode != MODE_DCRT && !cfg.sblast)
        g_sb = CreateWindowExW(0, L"S7Sidebar", L"WmuxSidebar", cs, RW(g_L.sb), g_top, NULL, g_inst, NULL);
    for (int j = 0; j < 2; j++) {
        int i = cfg.glswap ? 1 - j : j;
        if (i == 1 && cfg.nogl2) continue;
        RECT r = i == 0 ? g_L.gl1 : g_L.gl2;
        g_gl[i] = CreateWindowExW(0, L"S7GL", L"", cs, RW(r), g_top, NULL, g_inst, NULL);
        g_glp[i].hwnd = g_gl[i];
        g_glp[i].idx = i;
        SetWindowLongPtrW(g_gl[i], GWLP_USERDATA, (LONG_PTR)&g_glp[i]);
        if (!gl_init(&g_glp[i])) jlog("{\"t\":\"error\",\"what\":\"gl_init\",\"gle\":%lu}", GetLastError());
    }
    if (cfg.mode != MODE_DCRT && cfg.sblast)
        g_sb = CreateWindowExW(0, L"S7Sidebar", L"WmuxSidebar", cs, RW(g_L.sb), g_top, NULL, g_inst, NULL);
    if (cfg.webview) g_wvhost = CreateWindowExW(0, L"S7WebHost", L"", cs, RW(g_L.wv), g_top, NULL, g_inst, NULL);
    ShowWindow(g_top, SW_SHOWNOACTIVATE);
    layout();
    UpdateWindow(g_top);
    {
        BOOL cloaked = FALSE;
        DwmGetWindowAttribute(g_top, 14 /*DWMWA_CLOAKED*/, &cloaked, sizeof(cloaked));

        jlog("{\"t\":\"start\",\"tag\":\"%s\",\"pid\":%lu,\"pmv2\":%d,\"coinit\":\"0x%08lX\",\"dpi_top\":%u,"
             "\"client\":[%ld,%ld],\"cloaked\":%d,\"foreground_is_us\":%d}",
             cfg.tag, GetCurrentProcessId(), pm, (unsigned long)hrc, real_dpi(g_top), c.right, c.bottom, cloaked,
             GetForegroundWindow() == g_top);
    }
    if (cfg.webview) wv_start();
    PostMessageW(g_top, WM_APP_RUN, 0, 0);

    MSG msg;
    while (GetMessageW(&msg, NULL, 0, 0) > 0) {
        TranslateMessage(&msg);
        DispatchMessageW(&msg);
    }
    g_quit = 1;
    gl_stop(&g_glp[0]);
    gl_stop(&g_glp[1]);
    wv_stop();
    hrt_discard();
    flip_discard();
    dcrt_discard();
    release_layouts();
    if (g_tf_title) IDWriteTextFormat_Release(g_tf_title);
    if (g_tf_sub) IDWriteTextFormat_Release(g_tf_sub);
    if (g_dwf) IDWriteFactory_Release(g_dwf);
    if (g_d2f) ID2D1Factory1_Release(g_d2f);
    if (SUCCEEDED(hrc)) CoUninitialize();
    if (g_out) fclose(g_out);
    return 0;
}
