#!/bin/bash

# Configurations
DB_NAME="my_database"
DB_USER="postgres"
DB_PASSWORD="postgres"
APP_DIR="/home/medha/db/postgres/EFPostgreSQL"
LOG_DIR="/home/medha/db/postgres/logs"
LOG_FILE="$LOG_DIR/postgres_test_log_$(date +'%Y%m%d_%H%M%S').txt"
EMAIL="medhatiwari@ibm.com,Giridhar.Trivedi@ibm.com,Sanjam.Panda@ibm.com"
DOTNET_ROOT="/home/medha/packages/net9"
NPQ_DRIVER_REPO="https://github.com/npgsql/npgsql.git"
EFCORE_DRIVER_REPO="https://github.com/npgsql/efcore.pg.git"

# Export environment variables for dotnet
export DOTNET_ROOT="$DOTNET_ROOT"
export PATH="$DOTNET_ROOT:$PATH"

# Ensure log directory exists
mkdir -p "$LOG_DIR"

# Redirect output to log file
exec > >(tee -i "$LOG_FILE") 2>&1

cleanup() {
    echo "Performing cleanup..." >> "$LOG_FILE"
    export PATH="/usr/pgsql-13/bin:$PATH"
    [ -d "$APP_DIR" ] && rm -rf "$APP_DIR"
    [ -d "npgsql" ] && rm -rf npgsql
    [ -d "efcore.pg" ] && rm -rf efcore.pg
    sudo systemctl start postgresql >> "$LOG_FILE" 2>&1
    PGPASSWORD="$DB_PASSWORD" psql -U "$DB_USER" -c "DROP DATABASE IF EXISTS $DB_NAME;" >> "$LOG_FILE" 2>&1 || echo "Failed to drop database" >> "$LOG_FILE"
}
# Apply changes to files
apply_file_changes() {
    echo "Applying changes to project files..." >> "$LOG_FILE"

    # Update Directory.Build.props
    sed -i '/<AllowUnsafeBlocks>/a \
    <PublishAot>false</PublishAot>\
    <RuntimeIdentifier>linux-s390x</RuntimeIdentifier>\
    <RuntimeFrameworkVersion>9.0.0</RuntimeFrameworkVersion>' npgsql/Directory.Build.props

    # Update NuGet.config
    sed -i '/<packageSources>/a \
    <add key="localSource" value="/home/medha/nuget-source/" />' npgsql/NuGet.config

    # Update Npgsql.NativeAotTests.csproj
    sed -i 's/<PublishAot>true<\/PublishAot>/<PublishAot>false<\/PublishAot>/' npgsql/test/Npgsql.NativeAotTests/Npgsql.NativeAotTests.csproj
}
# Send email function
send_email() {
    local subject="PostgreSQL Test Results"
    local attachment="$LOG_FILE"
    {
        echo "Subject: $subject"
        echo "To: $EMAIL"
        echo "MIME-Version: 1.0"
        echo "Content-Type: multipart/mixed; boundary=\"boundary\""
        echo
        echo "--boundary"
        echo "Content-Type: text/plain; charset=UTF-8"
        echo "Content-Transfer-Encoding: 7bit"
        echo
        echo "Npgsql Driver Build/Test: $1"
        echo "EFCore.PG Driver Build/Test: $2"
        echo "Application: $3"
        echo
        echo "--boundary"
        echo "Content-Type: text/plain; name=$(basename "$attachment")"
        echo "Content-Disposition: attachment; filename=$(basename "$attachment")"
        echo "Content-Transfer-Encoding: base64"
        echo
        base64 "$attachment"
        echo "--boundary--"
    } | /usr/sbin/sendmail -t
}

# Trap errors to ensure email is sent even on failure
trap 'send_email "$NPQ_STATUS" "$EFCORE_STATUS" "$APP_STATUS"' EXIT

# Main logic
{
    # Cleanup before starting
    cleanup

    echo "Installing PostgreSQL..." >> "$LOG_FILE"
    sudo yum install -y postgresql postgresql-server postgresql-contrib >> "$LOG_FILE" 2>&1 || { echo "PostgreSQL installation failed" >> "$LOG_FILE"; exit 1; }
    sudo systemctl start postgresql >> "$LOG_FILE" 2>&1
    sudo systemctl enable postgresql >> "$LOG_FILE" 2>&1
    PGPASSWORD="$DB_PASSWORD" psql -U "$DB_USER" -c "ALTER USER $DB_USER PASSWORD '$DB_PASSWORD';" >> "$LOG_FILE" 2>&1
    PGPASSWORD="$DB_PASSWORD" psql -U "$DB_USER" -tc "SELECT 1 FROM pg_database WHERE datname = '$DB_NAME'" | grep -q 1 || \
        PGPASSWORD="$DB_PASSWORD" psql -U "$DB_USER" -c "CREATE DATABASE $DB_NAME;" >> "$LOG_FILE" 2>&1

    # Create the required npgsql_tests user
    PGPASSWORD="$DB_PASSWORD" psql -U "$DB_USER" -c "DO \$\$ BEGIN IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'npgsql_tests') THEN CREATE USER npgsql_tests PASSWORD 'npgsql_tests' SUPERUSER; END IF; END \$\$;" >> "$LOG_FILE" 2>&1

    echo "Building Npgsql driver..." >> "$LOG_FILE"
    git clone "$NPQ_DRIVER_REPO" npgsql >> "$LOG_FILE" 2>&1
    apply_file_changes
    cd npgsql || exit 1
    if dotnet build >> "$LOG_FILE" 2>&1; then
        if dotnet test >> "$LOG_FILE" 2>&1; then
            NPQ_STATUS="Success"
        else
            echo "Npgsql tests failed" >> "$LOG_FILE"
            NPQ_STATUS="Failure"
        fi
    else
        echo "Npgsql build failed" >> "$LOG_FILE"
        NPQ_STATUS="Failure"
    fi
    cd ..

    echo "Building EFCore.PG driver..." >> "$LOG_FILE"
    [ -d "efcore.pg" ] && rm -rf efcore.pg
    git clone "$EFCORE_DRIVER_REPO" efcore.pg >> "$LOG_FILE" 2>&1
    cd efcore.pg || exit 1
    if dotnet build >> "$LOG_FILE" 2>&1; then
        if dotnet test >> "$LOG_FILE" 2>&1; then
            EFCORE_STATUS="Success"
        else
            echo "EFCore.PG tests failed" >> "$LOG_FILE"
            EFCORE_STATUS="Failure"
        fi
    else
        echo "EFCore.PG build failed" >> "$LOG_FILE"
        EFCORE_STATUS="Failure"
    fi
    cd ..

    echo "Creating .NET application..." >> "$LOG_FILE"
    mkdir -p "$APP_DIR"
    cd "$APP_DIR" || exit 1
    dotnet new console -o EFPostgreSQL --force >> "$LOG_FILE" 2>&1
    cd EFPostgreSQL || exit 1
    dotnet add package Npgsql.EntityFrameworkCore.PostgreSQL >> "$LOG_FILE" 2>&1
    dotnet add package Microsoft.EntityFrameworkCore.Design >> "$LOG_FILE" 2>&1

    cat > Program.cs << EOF
using System;
using System.Linq;
using Microsoft.EntityFrameworkCore;

public class BloggingContext : DbContext
{
    public DbSet<Blog> Blogs { get; set; }

    protected override void OnConfiguring(DbContextOptionsBuilder optionsBuilder)
        => optionsBuilder.UseNpgsql("Host=localhost;Database=my_database;Username=postgres;Password=postgres;");

    protected override void OnModelCreating(ModelBuilder modelBuilder)
    {
        modelBuilder.Entity<Blog>().ToTable("Blogs");
    }
}

public class Blog
{
    public int BlogId { get; set; }
    public string Url { get; set; } = string.Empty;
}

public class Program
{
    public static void Main(string[] args)
    {
        using var db = new BloggingContext();

        // Ensure the database schema is created
        db.Database.EnsureCreated();

        Console.WriteLine("Inserting a new blog");
        db.Blogs.Add(new Blog { Url = "http://example.com" });
        db.SaveChanges();

        Console.WriteLine("Querying blogs");
        foreach (var blog in db.Blogs)
        {
            Console.WriteLine($"BlogId: {blog.BlogId}, Url: {blog.Url}");
        }
    }
}
EOF

    if dotnet run >> "$LOG_FILE" 2>&1; then
	echo "Application run successful" >> "$LOG_FILE"
        APP_STATUS="Success"
    else
        echo "Application run failed" >> "$LOG_FILE"
        APP_STATUS="Failure"
    fi

    echo "Script completed successfully." >> "$LOG_FILE"
} || {
    echo "An error occurred during the script execution." >> "$LOG_FILE"
    NPQ_STATUS="Failure"
    EFCORE_STATUS="Failure"
    APP_STATUS="Failure"
}

# Cleanup and send email
cleanup
send_email "$NPQ_STATUS" "$EFCORE_STATUS" "$APP_STATUS"
