#!/bin/bash

# Configurations
REPO_URL="https://github.com/mariadb-corporation/mariadb-connector-odbc.git"
CLONE_DIR="/home/medha/db/mariaDB/mariadb-connector-odbc"
LOG_DIR="/home/medha/db/mariaDB/logs"
LOG_FILE="$LOG_DIR/mariaDB_test_log_$(date +'%Y%m%d_%H%M%S').txt"
APP_DIR="/home/medha/db/mariaDB/MariaDB_ODBC_Test"
EMAIL="medhatiwari@ibm.com,Giridhar.Trivedi@ibm.com,Sanjam.Panda@ibm.com"
DOTNET_ROOT="/home/medha/packages/net8"
DB_NAME="odbc_test"
DSN_NAME="test"
DRIVER_NAME="MariaDB ODBC 3.1 Driver"
DRIVER_PATH="/usr/lib64/libmaodbc.so"
DB_USER="root"
DB_PASS="pass4root"
SERVER="localhost"

# Export environment variables
export DOTNET_ROOT="$DOTNET_ROOT"
export PATH="$DOTNET_ROOT:$PATH"
export LD_LIBRARY_PATH="/usr/lib64:$LD_LIBRARY_PATH"

# Ensure log directory exists
mkdir -p "$LOG_DIR"

# Initialize status variables
CONNECTOR_BUILD_STATUS="Failure"
CONNECTOR_TEST_STATUS="Failure"
APP_STATUS="Failure"

# Send email with results
send_email() {
    local build_status="$1"
    local test_status="$2"
    local app_status="$3"

    {
        echo "Subject: MariaDB Test Results"
        echo "To: $EMAIL"
        echo "MIME-Version: 1.0"
        echo "Content-Type: multipart/mixed; boundary=boundary"
        echo
        echo "--boundary"
        echo "Content-Type: text/plain; charset=UTF-8"
        echo "Content-Transfer-Encoding: 7bit"
        echo
        echo "MariaDB connector build - Status: $build_status"
        echo "MariaDB connector tests - Status: $test_status"
        echo "Application - Status: $app_status"
        echo
        echo "--boundary"
        echo "Content-Type: text/plain; name=$(basename "$LOG_FILE")"
        echo "Content-Disposition: attachment; filename=$(basename "$LOG_FILE")"
        echo "Content-Transfer-Encoding: base64"
        echo
        base64 "$LOG_FILE"
        echo "--boundary--"
    } | /usr/sbin/sendmail -t
}

# Start logging
echo "Starting MariaDB .NET Connector Test Script..." | tee "$LOG_FILE"

# Cleanup function
cleanup() {
    echo "Performing cleanup..." | tee -a "$LOG_FILE"
    rm -rf "$CLONE_DIR" "$APP_DIR"
}

# Install required packages
install_packages() {
    echo "Installing required packages..." | tee -a "$LOG_FILE"
    REQUIRED_PACKAGES=("gcc" "gcc-c++" "make" "cmake" "unixODBC" "unixODBC-devel" "mariadb-connector-odbc" "mariadb-server")
    for pkg in "${REQUIRED_PACKAGES[@]}"; do
        if ! rpm -q "$pkg" > /dev/null 2>&1; then
            echo "Installing $pkg..." | tee -a "$LOG_FILE"
            if ! dnf install -y "$pkg" >> "$LOG_FILE" 2>&1; then
                echo "Failed to install $pkg." | tee -a "$LOG_FILE"
                exit 1
            fi
        fi
    done
    echo "All packages installed successfully." | tee -a "$LOG_FILE"
}

# Configure MariaDB server
configure_mariadb() {
    echo "Configuring MariaDB server..." | tee -a "$LOG_FILE"
    systemctl start mariadb.service >> "$LOG_FILE" 2>&1
    systemctl enable mariadb.service >> "$LOG_FILE" 2>&1

    echo "Checking authentication method for root user..." | tee -a "$LOG_FILE"
    PLUGIN=$(mysql -uroot -e "SELECT plugin FROM mysql.user WHERE user = 'root';" 2>/dev/null | tail -n 1)
    if [[ "$PLUGIN" != "mysql_native_password" ]]; then
        echo "Updating authentication method to mysql_native_password..." | tee -a "$LOG_FILE"
        mysql -uroot -e "ALTER USER 'root'@'localhost' IDENTIFIED WITH mysql_native_password BY '$DB_PASS';" >> "$LOG_FILE" 2>&1
        mysql -uroot -e "FLUSH PRIVILEGES;" >> "$LOG_FILE" 2>&1
    fi

    if ! mysql -uroot -p"$DB_PASS" -e "QUIT" 2>/dev/null; then
        echo "Failed to authenticate with root password." | tee -a "$LOG_FILE"
        exit 1
    fi

    mysql -uroot -p"$DB_PASS" -e "CREATE DATABASE IF NOT EXISTS $DB_NAME;" >> "$LOG_FILE" 2>&1
    mysql -uroot -p"$DB_PASS" -e "GRANT ALL PRIVILEGES ON $DB_NAME.* TO 'root'@'localhost';" >> "$LOG_FILE" 2>&1
    mysql -uroot -p"$DB_PASS" -e "GRANT ALL PRIVILEGES ON *.* TO 'root'@'localhost' WITH GRANT OPTION;" >> "$LOG_FILE" 2>&1
    echo "MariaDB server configured." | tee -a "$LOG_FILE"
}

# Build and test connector
build_and_test_connector() {
    echo "Cloning MariaDB Connector/ODBC repository..." | tee -a "$LOG_FILE"
    rm -rf "$CLONE_DIR"
    git clone "$REPO_URL" "$CLONE_DIR" >> "$LOG_FILE" 2>&1 || {
        echo "Failed to clone repository." | tee -a "$LOG_FILE"
        exit 1
    }

    echo "Building MariaDB Connector/ODBC..." | tee -a "$LOG_FILE"
    cd "$CLONE_DIR"
    cmake . >> "$LOG_FILE" 2>&1
    if make -j2 >> "$LOG_FILE" 2>&1; then
        CONNECTOR_BUILD_STATUS="Success"
    else
        echo "Build failed." | tee -a "$LOG_FILE"
        return
    fi

    echo "Running ctest..." | tee -a "$LOG_FILE"
    cd test
    if ctest --verbose >> "$LOG_FILE" 2>&1; then
        CONNECTOR_TEST_STATUS="Success"
    else
        echo "Tests failed." | tee -a "$LOG_FILE"
    fi
}

# Create and test .NET application
test_dotnet_application() {
    echo "Creating .NET application..." | tee -a "$LOG_FILE"
    rm -rf "$APP_DIR"
    if ! dotnet new console -o "$APP_DIR" >> "$LOG_FILE" 2>&1; then
        echo "Failed to create .NET application." | tee -a "$LOG_FILE"
        return
    fi

    cd "$APP_DIR"
    if ! dotnet add package System.Data.Odbc >> "$LOG_FILE" 2>&1; then
        echo "Failed to add ODBC package." | tee -a "$LOG_FILE"
        return
    fi

    cat > Program.cs << EOF
using System;
using System.Data.Odbc;

class Program
{
    static void Main()
    {
        string connString = "DSN=${DSN_NAME};";
        try
        {
            using (var conn = new OdbcConnection(connString))
            {
                conn.Open();
                Console.WriteLine("Connection to MariaDB succeeded.");

                var cmd = conn.CreateCommand();
                cmd.CommandText = "SELECT 1;";
                var reader = cmd.ExecuteReader();
                while (reader.Read())
                {
                    Console.WriteLine("{0}", reader[0]);
                }
            }
        }
        catch (Exception ex)
        {
            Console.WriteLine($"Failed to connect or execute query: {ex.Message}");
        }
    }
}
EOF

    if dotnet build >> "$LOG_FILE" 2>&1; then
        if dotnet run >> "$LOG_FILE" 2>&1; then
	    echo "Application run: Successful" | tee -a "$LOG_FILE"
            APP_STATUS="Success"
        else
            echo "Application failed to run." | tee -a "$LOG_FILE"
        fi
    else
        echo "Application build failed." | tee -a "$LOG_FILE"
    fi
}

# Main script
trap 'cleanup; send_email "$CONNECTOR_BUILD_STATUS" "$CONNECTOR_TEST_STATUS" "$APP_STATUS"' EXIT
install_packages
configure_mariadb
build_and_test_connector
test_dotnet_application
cleanup

exit 0


