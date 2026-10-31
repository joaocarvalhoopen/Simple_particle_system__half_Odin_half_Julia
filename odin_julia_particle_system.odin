package main

import "core:fmt"
import "core:c"
import "core:math"
import "core:math/rand"
import rl "vendor:raylib"

// C ABI connection with the C lib from Julia
foreign import julia "system:julia"

// Data struct
jl_value_t :: struct { }

@(default_calling_convention="c")
foreign julia {

    jl_init              :: proc( ) ---
    jl_eval_string       :: proc( str : cstring )     -> ^jl_value_t ---
    jl_unbox_voidpointer :: proc( v   : ^jl_value_t ) -> rawptr ---
}

// Partícle definition
// When we create a '#soa []Particle', Odin will create 5 separate continue arrays:
// [ x0, x1, x2, ... ], [ y0, y1, y2, ... ], [ vx0, vx1, ... ], [ vy0, vy1, ... ], [ color0, color1, ... ]
Particle :: struct {

    x, y   : f32,
    vx, vy : f32,
    color    : u32, // RGBA packad in 32 bits ( rl.Color )
}

// Physiscs engine in Júlia, it receives 5 separate SOA ponters.
Julia_SOA_Simulator :: #type proc "c" (

    px, py           : [^]f32,
    pvx, pvy         : [^]f32,
    pcolor           : [^]u32,
    n                : c.size_t,
    mouse_x, mouse_y : f32,
    dt               : f32,
    iteractive_mode  : c.int,
)

// Odin callback called by Julia from the SIMD cicle:
// We receive the square of the velocity and return a RGBA color, plasma gradiante.
@(export)
odin_color_velocity :: proc "c" ( vel_sq : f32 ) -> u32 {

    t := math.clamp( math.sqrt( vel_sq ) / 450.0, 0.0, 1.0 )

    // Smoth gradiante : Deep blue -> Cian -> Magenta -> Warm Yellow
    r := u8( math.clamp( t * t * 255.0 + 30.0, 0.0, 255.0 ) )
    g := u8( math.clamp( math.sin( t * math.PI ) * 220.0 + ( t * 60.0 ), 0.0, 255.0 ) )
    b := u8( math.clamp( ( 1.0 - t * 0.7 ) * 255.0, 0.0, 255.0 ) )
    a := u8( 200 )

    // Package the data in little endian format to be compatible with rl.Color ( R, G, B, A )
    return u32( r ) | ( u32( g ) << 8 ) | ( u32( b ) << 16 ) | ( u32( a ) << 24 )
}

WIDTH     :: 1980
HEIGHT    :: 1080
NUM_PART  :: 250_000 // 100_000 // 40_000

main :: proc( ) {

    // Start the Julia engine.
    jl_init( )

    // The Julia code : Works directly over the 5 SOA arrays of Odin without allocating nothing
    julia_code : cstring = `

    module VorticeEngineSOA
        const cb_color = Ref{ Ptr{ Cvoid } }( C_NULL )

        function register_callback( ptr::Ptr{ Cvoid } )
            cb_color[ ] = ptr
            return nothing
        end

        function update_soa!(
            px::Ptr{ Float32 }, py::Ptr{ Float32 },
            pvx::Ptr{ Float32 }, pvy::Ptr{ Float32 },
            pcolor::Ptr{ UInt32 },
            n::Csize_t,
            mx::Float32, my::Float32,
            dt::Float32, mode::Cint
        )::Cvoid

            # Zero copy views for each channel of #soa of Odin
            x   = unsafe_wrap( Array, px, n; own=false )
            y   = unsafe_wrap( Array, py, n; own=false )
            vx  = unsafe_wrap( Array, pvx, n; own=false )
            vy  = unsafe_wrap( Array, pvy, n; own=false )
            color = unsafe_wrap( Array, pcolor, n; own=false )

            fn_color = cb_color[]

            # Vectorized @simd cicle directly in the contiguos f32 arrays
            @inbounds @simd for i in 1:n
                dx = mx - x[ i ]
                dy = my - y[ i ]
                dist_sq = dx * dx + dy * dy + 150.0f0
                inv_dist = 1.0f0 / sqrt( dist_sq )

                # Normalized direction and tangent vector, vortice rotation
                nx = dx * inv_dist
                ny = dy * inv_dist
                tx = -ny
                ty = nx

                # Atraction and repulsion forces + the spining vortice
                force_radial = mode == 1 ? 320.0f0 : ( mode == 2 ? -650.0f0 : 110.0f0 )
                force_vortice = 190.0f0 * ( 8000.0f0 / ( dist_sq + 8000.0f0 ) )

                # Harmonic flux field to make the continuos movement more natural apperance
                flux_x = sin( y[ i ] * 0.008f0 ) * 35.0f0
                flux_y = cos( x[ i ] * 0.008f0 ) * 35.0f0

                nvx = ( vx[ i ] + ( nx * force_radial + tx * force_vortice + flux_x ) * dt ) * 0.988f0
                nvy = ( vy[ i ] + ( ny * force_radial + ty * force_vortice + flux_y ) * dt ) * 0.988f0

                nx_pos = x[ i ] + nvx * dt
                ny_pos = y[ i ] + nvy * dt

                # Mantain inside the screen size, smoth wrap around
                if nx_pos < 0.0f0

                	nx_pos += 1980.0f0
                elseif nx_pos >= 1980.0f0

                	nx_pos -= 1980.0f0
                 end

                if ny_pos < 0.0f0

                	ny_pos += 1080.0f0
                elseif ny_pos >= 1080.0f0

                	ny_pos -= 1080.0f0
                end

                x[ i ]  = nx_pos
                y[ i ]  = ny_pos
                vx[ i ] = nvx
                vy[ i ] = nvy

                # Calls Odin back to get the color, based on the cinectic energy
                vel_sq = nvx * nvx + nvy * nvy
                color[ i ] = ccall( fn_color, UInt32, ( Float32, ), vel_sq )
            end

            return nothing
        end

        function get_pointer( )

            return @cfunction(
                update_soa!, Cvoid,
                ( Ptr{ Float32 }, Ptr{ Float32 }, Ptr{ Float32 }, Ptr{ Float32 }, Ptr{ UInt32 },
                 Csize_t, Float32, Float32, Float32, Cint )
            )

        end
    end
    `

    jl_eval_string( julia_code )

    // Register the callback function of the color of Odin in Julia
    cmd_cb := fmt.ctprintf(
        "VorticeEngineSOA.register_callback( Ptr{{ Cvoid }}( UInt( %p ) ) )",
        rawptr( odin_color_velocity ),
    )
    jl_eval_string( cmd_cb )

    // Gets the compiled pointer from Julia
    ptr_julia := jl_eval_string( "VorticeEngineSOA.get_pointer()" )
    assert( ptr_julia != nil, "Julia returned nil! Check for syntax errors in julia_code." )
    julia_simulate := cast( Julia_SOA_Simulator ) jl_unbox_voidpointer( ptr_julia )

    // Alocates SOA memory in Odin
    particles : #soa [ ]Particle = make_soa( #soa [ ]Particle, NUM_PART )
    defer delete_soa( particles )

    // Initial random positions
    for i in 0 ..< NUM_PART {

        particles[ i ].x     = rand.float32_range( 0, WIDTH )
        particles[ i ].y     = rand.float32_range( 0, HEIGHT )
        particles[ i ].vx    = rand.float32_range( -20, 20 )
        particles[ i ].vy    = rand.float32_range( -20, 20 )
        particles[ i ].color = 0xFFFFFFFF
    }

    // RAYLIB

    // Initialize the raylib window.
    rl.InitWindow( WIDTH, HEIGHT, "Odin ( #soa + Raylib ) <-> Julia ( @simd AVX ) - 40.000 Particles" )
    defer rl.CloseWindow( )
    rl.SetTargetFPS( 60 )

    //  Real time main loop at 60 Hz
    for !rl.WindowShouldClose( ) {

        dt    := rl.GetFrameTime( )
        mouse := rl.GetMousePosition( )

        mode : c.int = 0
        if rl.IsMouseButtonDown( .LEFT )  do mode = 1 // Strong atraction
        if rl.IsMouseButtonDown( .RIGHT ) do mode = 2 // Repel Explosion

        // Zero copy SOA call:
        // We pass each individual pointer of each SOA channel of the SOA Strucure
        julia_simulate(
            particles.x,
            particles.y,
            particles.vx,
            particles.vy,
            particles.color,
            c.size_t( NUM_PART ),
            mouse.x,
            mouse.y,
            dt,
            mode,
        )

        // Draw the window
        rl.BeginDrawing( )

        // semi transparen or pure black background
        rl.ClearBackground( rl.Color{ 8, 10, 18, 255 } )

        // Draw with Additive Blending so that the particles become brigther when they super impose.
        rl.BeginBlendMode( .ADDITIVE )

        for i in 0 ..< NUM_PART {

            pos   := rl.Vector2{ particles.x[ i ], particles.y[ i ] }
            color := transmute( rl.Color ) particles.color[ i ]
            rl.DrawPixelV( pos, color )
        }

        rl.EndBlendMode( )

        // Interface
        rl.DrawRectangle( 10, 10, 490, 85, rl.Color{ 0, 0, 0, 180 } )
        rl.DrawFPS( 20, 20)
        rl.DrawText( "Odin #soa [ ]Particles <-> Julia @simd Zero copy", 20, 45, 18, rl.RAYWHITE )
        rl.DrawText( "Left mouse: Black hole | Right mouse: Choque wave", 20, 70, 16, rl.SKYBLUE )

        rl.EndDrawing( )
    }
}
