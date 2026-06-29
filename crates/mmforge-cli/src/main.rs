//! MMForge CLI — command-line interface for model inspection and conversion.

use clap::Parser;

/// MMForge: Industrial 2D/3D model parser and native renderer.
#[derive(Parser)]
#[command(
    name = "mmforge",
    version,
    about = "Industrial 2D/3D model parser and native renderer"
)]
struct Cli {
    #[command(subcommand)]
    command: Option<Commands>,
}

#[derive(Parser)]
enum Commands {
    /// Display version and build information.
    Version,
}

fn main() {
    let cli = Cli::parse();

    match cli.command {
        Some(Commands::Version) | None => {
            println!("mmforge {}", mmforge_core::VERSION);
            println!("  core    {}", mmforge_core::VERSION);
            println!("  license MIT OR Apache-2.0");
        }
    }
}
