use anyhow::{Context, Result};
use clap::{Parser, Subcommand};
use serde::{Deserialize, Serialize};
use std::path::PathBuf;

// ── CLI ──────────────────────────────────────────────────────────────────────

#[derive(Parser)]
#[command(name = "aon-card", about = "A2A agent card generator and NATS publisher")]
struct Cli {
    #[command(subcommand)]
    cmd: Cmd,
}

#[derive(Subcommand)]
enum Cmd {
    /// Generate A2A card from prompt frontmatter → agents/<role>.json
    Gen {
        role: String,
        #[arg(long, default_value = "agent-prompts")]
        prompts_dir: PathBuf,
        #[arg(long, default_value = "agents")]
        agents_dir: PathBuf,
        #[arg(long, default_value = "unknown-team")]
        team: String,
        #[arg(long, default_value = "nats://localhost:4222")]
        nats_url: String,
    },
    /// Publish agents/<role>.json to NATS KV + subject
    Publish {
        role: String,
        #[arg(long, default_value = "agents")]
        agents_dir: PathBuf,
        #[arg(long)]
        creds: Option<PathBuf>,
        #[arg(long, default_value = "nats://localhost:4222")]
        nats_url: String,
        #[arg(long, default_value = "team-state")]
        kv_bucket: String,
    },
}

// ── A2A card types ───────────────────────────────────────────────────────────

#[derive(Debug, Serialize, Deserialize)]
struct AgentSkill {
    id: String,
    name: String,
    description: String,
    tags: Vec<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    mentor: Option<bool>,
}

#[derive(Debug, Serialize, Deserialize)]
struct AgentCard {
    name: String,
    description: String,
    url: String,
    version: String,
    skills: Vec<AgentSkill>,
    #[serde(rename = "defaultInputModes")]
    default_input_modes: Vec<String>,
    #[serde(rename = "defaultOutputModes")]
    default_output_modes: Vec<String>,
    /// Extension: role kind (manager | generalist | specialist)
    #[serde(rename = "x-aon-kind", skip_serializing_if = "Option::is_none")]
    x_aon_kind: Option<String>,
    /// Extension: aon role type for routing (worker | manager)
    #[serde(skip_serializing_if = "Option::is_none")]
    role: Option<String>,
}

// ── Frontmatter types ────────────────────────────────────────────────────────

#[derive(Debug, Deserialize)]
struct Frontmatter {
    #[serde(default)]
    kind: Option<String>,
    #[serde(default)]
    description: Option<String>,
    #[serde(default)]
    skills: Vec<FrontmatterSkill>,
}

#[derive(Debug, Deserialize)]
struct FrontmatterSkill {
    id: String,
    #[serde(default)]
    name: Option<String>,
    #[serde(default)]
    description: Option<String>,
    #[serde(default)]
    tags: Vec<String>,
    #[serde(default)]
    mentor: Option<bool>,
}

// ── Frontmatter parser ───────────────────────────────────────────────────────

fn parse_frontmatter(content: &str) -> Result<Frontmatter> {
    let content = content.trim_start();
    if !content.starts_with("---") {
        return Ok(Frontmatter { kind: None, description: None, skills: vec![] });
    }
    let rest = &content[3..];
    let end = rest.find("\n---").context("unclosed YAML frontmatter (missing closing ---)")?;
    let yaml = &rest[..end];
    serde_yaml::from_str(yaml).context("invalid YAML in frontmatter")
}

// ── gen ──────────────────────────────────────────────────────────────────────

fn cmd_gen(
    role: &str,
    prompts_dir: &PathBuf,
    agents_dir: &PathBuf,
    team: &str,
    nats_url: &str,
) -> Result<()> {
    let prompt_path = prompts_dir.join(format!("{role}.md"));
    let content = std::fs::read_to_string(&prompt_path)
        .with_context(|| format!("cannot read {}", prompt_path.display()))?;

    let fm = parse_frontmatter(&content)?;

    let kind = fm.kind.as_deref().unwrap_or("unknown");
    let role_type = if kind == "manager" { "manager" } else { "worker" }.to_string();

    let skills = fm
        .skills
        .into_iter()
        .map(|s| AgentSkill {
            id: s.id.clone(),
            name: s.name.unwrap_or_else(|| s.id.clone()),
            description: s.description.unwrap_or_default(),
            tags: s.tags,
            mentor: s.mentor,
        })
        .collect();

    // Strip port from nats_url for the card url field (aesthetic only)
    let base_url = nats_url.trim_end_matches('/');
    let card = AgentCard {
        name: role.to_string(),
        description: fm
            .description
            .unwrap_or_else(|| format!("{role} — {kind}")),
        url: format!("{base_url}/{team}/agents/{role}"),
        version: "1.0.0".to_string(),
        skills,
        default_input_modes: vec!["text".to_string()],
        default_output_modes: vec!["text".to_string()],
        x_aon_kind: Some(kind.to_string()),
        role: Some(role_type),
    };

    std::fs::create_dir_all(agents_dir)
        .with_context(|| format!("cannot create {}", agents_dir.display()))?;

    let out_path = agents_dir.join(format!("{role}.json"));
    let json = serde_json::to_string_pretty(&card)?;
    std::fs::write(&out_path, &json)
        .with_context(|| format!("cannot write {}", out_path.display()))?;

    eprintln!("aon-card: wrote {}", out_path.display());
    Ok(())
}

// ── publish ──────────────────────────────────────────────────────────────────

#[tokio::main]
async fn cmd_publish(
    role: &str,
    agents_dir: &PathBuf,
    creds: &Option<PathBuf>,
    nats_url: &str,
    kv_bucket: &str,
) -> Result<()> {
    let card_path = agents_dir.join(format!("{role}.json"));
    let card_bytes = std::fs::read(&card_path)
        .with_context(|| format!("cannot read {}", card_path.display()))?;

    // Connect to NATS
    let mut opts = async_nats::ConnectOptions::new();
    if let Some(creds_path) = creds {
        opts = opts.credentials_file(creds_path).await
            .with_context(|| format!("cannot load creds {}", creds_path.display()))?;
    }
    let nc = opts.connect(nats_url).await
        .with_context(|| format!("cannot connect to NATS {nats_url}"))?;

    let js = async_nats::jetstream::new(nc.clone());

    // Store in KV bucket
    match js.get_key_value(kv_bucket).await {
        Ok(kv) => {
            let key = format!("agents.{role}.card");
            kv.put(&key, card_bytes.clone().into()).await
                .with_context(|| format!("KV put failed for key {key}"))?;
            eprintln!("aon-card: KV {kv_bucket}/{key} updated");
        }
        Err(e) => {
            eprintln!("aon-card: warn: KV bucket {kv_bucket} not found ({e}), skipping KV put");
        }
    }

    // Also publish to subject for subscribers
    let subject = format!("agents.{role}.card");
    nc.publish(subject.clone(), card_bytes.into()).await
        .with_context(|| format!("publish to {subject} failed"))?;
    nc.flush().await?;
    eprintln!("aon-card: published to {subject}");

    Ok(())
}

// ── main ─────────────────────────────────────────────────────────────────────

fn main() -> Result<()> {
    let cli = Cli::parse();
    match &cli.cmd {
        Cmd::Gen { role, prompts_dir, agents_dir, team, nats_url } => {
            cmd_gen(role, prompts_dir, agents_dir, team, nats_url)
        }
        Cmd::Publish { role, agents_dir, creds, nats_url, kv_bucket } => {
            cmd_publish(role, agents_dir, creds, nats_url, kv_bucket)
        }
    }
}
